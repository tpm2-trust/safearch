#!/usr/bin/env bash
# Prepare a distribution server: it receives releases from the build host
# (one at a time, each replacing the last), serves them for network boot
# (HTTP, optionally DHCP/PXE) and for writing sticks, and checks every upload. Needs no signing
# key, only the public db certificate. Run from a checkout of this repository,
# as root; running it again applies changed settings and keeps everything else.
#
#   sudo server/setup.sh --db-cert db.pem [--upload-key KEY.pub]... [--no-packages]
#
#   --db-cert FILE     the public Secure Boot db certificate the builds are
#                      signed with (on the build host:
#                      mkosi.extra/usr/share/safespace/secureboot/db.pem).
#                      Needed on the first run; later only to replace it
#                      (then also --replace-db-cert).
#   --upload-key FILE  ssh public key of the build host's releasing user
#                      (repeatable). It may only rsync into the share: no
#                      shell, no reading, no deleting.
#   --no-packages      do not install packages (they are there already)
#
# Arch Linux only (as the images). What it sets up:
#   /etc/safespace/server.conf      settings (from server/server.conf or the
#                                   example, once; edit it, then rerun)
#   /etc/safespace/db.pem           the pinned db certificate
#   user safespace                  owns the share, runs the checks; its ssh
#                                   login is the upload account (rrsync)
#   $SHARE (/srv/safespace/share)   the release
#   /usr/local/bin/safespace-netboot (+ /usr/local/lib/safespace-server/)
#   units: safespace-netboot-verify.path/.service, safespace-dhcp.service
#   nginx: the share under http://<server>/safespace/
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
REPO=$(dirname "$HERE")
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m==> WARNING:\e[0m %s\n' "$*" >&2; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; }

DB="" REPLACE_DB=0 KEYS=() PACKAGES=1
while (($#)); do
	case $1 in
		--db-cert) DB=${2:?--db-cert needs a file}; shift 2 ;;
		--replace-db-cert) REPLACE_DB=1; shift ;;
		--upload-key) KEYS+=("${2:?--upload-key needs a file}"); shift 2 ;;
		--no-packages) PACKAGES=0; shift ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die "unknown option $1" ;;
	esac
done
[[ $EUID -eq 0 ]] || die "must run as root"

ETC=/etc/safespace
USER_NAME=safespace
HOME_DIR=/var/lib/safespace

# --- packages ----------------------------------------------------------------------

[[ -f /etc/arch-release ]] || die "distribution servers run Arch Linux (as the build host and the images)"
PKGS=(nginx dnsmasq rsync python openssh sbsigntools cryptsetup zstd mtools util-linux binutils openssl)
if ((PACKAGES)); then
	log "Installing: ${PKGS[*]}"
	pacman -S --needed --noconfirm "${PKGS[@]}"
fi
for cmd in nginx dnsmasq rsync sbverify veritysetup zstd mcopy sfdisk objcopy openssl flock runuser; do
	command -v "$cmd" >/dev/null || die "missing '$cmd'"
done
RRSYNC=$(command -v rrsync) || die "rrsync not found (part of the rsync package)"

# --- settings and the pinned certificate ---------------------------------------------

install -d -m 0755 "$ETC" "$ETC/dnsmasq.d"
if [[ ! -f $ETC/server.conf ]]; then
	src=$HERE/server.conf
	[[ -f $src ]] || src=$HERE/server.conf.example
	install -m 0644 "$src" "$ETC/server.conf"
	log "Installed $ETC/server.conf from $(basename "$src"): check SERVER_URL= and DHCP_*"
fi
chown root:root "$ETC/server.conf"
chmod 0644 "$ETC/server.conf"
# shellcheck source=server.conf.example
source "$ETC/server.conf"
SHARE=${SHARE:-/srv/safespace/share}
[[ $SHARE == /* && $SHARE != *[[:space:]]* && $SHARE != / ]] || die "SHARE= must be an absolute path"

if [[ -n $DB ]]; then
	openssl x509 -in "$DB" -noout 2>/dev/null || die "$DB is not a PEM certificate"
	grep -q 'PRIVATE KEY' "$DB" && die "$DB contains a private key: give the public certificate only"
	if [[ -f $ETC/db.pem ]] && ! cmp -s "$DB" "$ETC/db.pem"; then
		((REPLACE_DB)) || die "$ETC/db.pem exists with another certificate; to replace it add --replace-db-cert"
		warn "replacing the pinned db certificate: releases signed with the old key are no longer accepted"
	fi
	install -m 0644 "$DB" "$ETC/db.pem"
fi
[[ -f $ETC/db.pem ]] || die "no pinned certificate yet: --db-cert db.pem (from the build host)"
log "Pinned db certificate: $(openssl x509 -in "$ETC/db.pem" -noout -subject -nameopt oneline | sed 's/^subject=//')"
log "                       $(openssl x509 -in "$ETC/db.pem" -noout -fingerprint -sha256)"

# --- the service user / upload account -------------------------------------------------

if ! id "$USER_NAME" >/dev/null 2>&1; then
	log "Creating system user $USER_NAME"
	useradd --system --user-group --home-dir "$HOME_DIR" --create-home --shell /bin/sh "$USER_NAME"
fi
# The home directory and authorized_keys belong to root: the account cannot
# change its own restrictions.
install -d -m 0755 -o root -g root "$HOME_DIR" "$HOME_DIR/.ssh"
install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "$HOME_DIR/state"
ak=$HOME_DIR/.ssh/authorized_keys
touch "$ak"
for key in "${KEYS[@]}"; do
	line=$(grep -v '^[[:space:]]*\(#\|$\)' "$key" | head -1)
	[[ $line =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+|sk-[a-z0-9@.-]+)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] ||
		die "$key: not an ssh public key"
	k=$(awk '{ print $1, $2 }' <<<"$line")
	if ! grep -qF "$k" "$ak"; then
		printf 'command="%s -wo -no-del -munge %s",restrict %s\n' "$RRSYNC" "$SHARE" "$line" >>"$ak"
		log "Upload key added: ${line:0:40}..."
	fi
done
# Keys that were added by hand without the restriction would be a shell.
if grep -v '^[[:space:]]*\(#\|$\)' "$ak" | grep -qv '^command="'; then
	die "$ak has keys without the rrsync restriction: remove them"
fi
chown root:root "$ak"
chmod 0644 "$ak"
[[ -s $ak ]] || warn "no upload key yet: --upload-key <build host user's key>.pub (until then only a local share push works)"

# --- share, tool, units -------------------------------------------------------------------

install -d -m 0755 "$(dirname "$SHARE")"
install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "$SHARE"
# The layout before one build served both boot paths.
for d in network usb; do
	[[ -d $SHARE/$d ]] && warn "$SHARE/$d is from an older layout and no longer served: remove it (rm -rf $SHARE/$d)"
done
install -d -m 0755 /usr/local/lib/safespace-server
install -m 0644 "$REPO/lib/verify.sh" /usr/local/lib/safespace-server/verify.sh
install -m 0755 "$HERE/safespace-netboot" /usr/local/bin/safespace-netboot
DNSMASQ=$(command -v dnsmasq)
for unit in safespace-netboot-verify.path safespace-netboot-verify.service safespace-dhcp.service; do
	sed -e "s|@SHARE@|$SHARE|g" -e "s|@DNSMASQ@|$DNSMASQ|g" "$HERE/systemd/$unit" >"/etc/systemd/system/$unit"
	chmod 0644 "/etc/systemd/system/$unit"
done

# --- nginx --------------------------------------------------------------------------------

# Arch ships neither conf.d/ nor an include for it.
install -d /etc/nginx/conf.d
sed "s|@SHARE@|$SHARE|g" "$HERE/nginx/safespace.conf" >/etc/nginx/conf.d/safespace.conf
grep -q 'include[[:space:]]\+conf\.d/\*\.conf' /etc/nginx/nginx.conf ||
	sed -i 's|^\(\s*\)http\s*{|&\n\1    include conf.d/*.conf;|' /etc/nginx/nginx.conf
nginx -t 2>&1 | sed 's/^/    /' || true
nginx -t >/dev/null 2>&1 ||
	die "nginx configuration invalid (another default_server, e.g. an older /etc/nginx/conf.d/netboot.conf? remove it and rerun)"

# --- enable --------------------------------------------------------------------------------

systemctl daemon-reload
systemctl enable --now nginx.service
systemctl reload nginx.service
systemctl enable --now safespace-netboot-verify.path
if [[ -s $ak ]]; then
	systemctl enable --now sshd.service
fi
case ${DHCP_MODE:-off} in
	proxy | dhcp)
		systemctl enable safespace-dhcp.service
		systemctl restart safespace-dhcp.service
		log "safespace-dhcp: DHCP_MODE=$DHCP_MODE on ${DHCP_INTERFACE:-?}" ;;
	off) systemctl disable --now safespace-dhcp.service 2>/dev/null || true
		log "safespace-dhcp: off (the network's DHCP server sends the boot options)" ;;
	*) die "DHCP_MODE=$DHCP_MODE: off, proxy or dhcp" ;;
esac

# Check what is already served (also records it for safespace-netboot status).
safespace-netboot verify || warn "a served release is broken (see above): release it again from the build host"

host=$(uname -n)
log "Ready."
cat <<EOF
    upload (build host):  ./release.sh --push $USER_NAME@$host
    served:               ${SERVER_URL%/}/boot.efi   (DHCP option 67); sticks: burn.sh ${SERVER_URL%/}/ /dev/sdX
    build host netboot:   NETROOT_URL=${SERVER_URL%/}/   (safespace.local.conf)
    state:                safespace-netboot status;  journalctl -u safespace-netboot-verify
    firewall:             TCP 22 (upload), TCP 80 (HTTP)$( [[ ${DHCP_MODE:-off} != off ]] && echo ", UDP 67, 69 and 4011 (DHCP/PXE/TFTP)")
EOF
