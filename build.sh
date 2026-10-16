#!/usr/bin/env bash
# Build one of the two safespace-arch variants with mkosi.
#
#   sudo ./build.sh usb     [MKOSI OPTIONS...]
#   sudo ./build.sh network [--url BASE_URL]... [MKOSI OPTIONS...]
#
#   usb      a bootable USB stick / SD card: ESP with signed systemd-boot and
#            UKI, erofs root and its dm-verity hash tree on the medium.
#            Write it with ./burn.sh, check it with ./diagnose.sh.
#   network  UEFI HTTP (or PXE/TFTP) netboot: the signed UKI plus the root
#            image and its hash tree as separate files, to be published with
#            ./netboot-export.sh. See NETBOOT.md.
#
# The network variant needs the base URL of the netboot tree on the server.
# The build appends its own image version to it, e.g.
#   --url http://10.0.0.1/safespace/  ->  http://10.0.0.1/safespace/20261016-1830/
# so a UKI always loads the root image it was signed with. Give --url more
# than once for failover (tried in order), or put it in netboot.conf
# (NETROOT_URL=, see netboot.conf.example) and leave the option out.
#
# Everything after the variant (and --url) is passed to mkosi unchanged, e.g.
#   sudo ./build.sh usb -f          force a rebuild of unchanged packages
#   sudo ./build.sh network summary show the resolved configuration
#
# Building needs root, because the UKI is signed with the sbctl db key in
# /var/lib/sbctl, which is readable by root only. Read-only verbs (summary,
# cat-config) run as a normal user.
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; }

VARIANT=${1:-}
case $VARIANT in
	usb | network) shift ;;
	-h | --help) usage; exit 0 ;;
	'') usage >&2; exit 1 ;;
	*) usage >&2; die "unknown variant '$VARIANT' (expected usb or network)" ;;
esac

URLS=()
NETROOT=()
MKOSI_ARGS=()
while (($#)); do
	case $1 in
		--url) URLS+=("${2:?--url needs a base URL}"); shift 2 ;;
		--url=*) URLS+=("${1#--url=}"); shift ;;
		-h | --help) usage; exit 0 ;;
		*) MKOSI_ARGS+=("$1"); shift ;;
	esac
done

command -v mkosi >/dev/null || die "mkosi not found (pacman -S mkosi)"

# No verb in the arguments: build. Only the verbs that touch the image need root.
VERB=build
for a in ${MKOSI_ARGS[@]+"${MKOSI_ARGS[@]}"}; do
	case $a in
		build | summary | cat-config | shell | boot | vm | qemu | ssh | journalctl | clean | sysupdate | sandbox | burn | documentation | dependencies)
			VERB=$a; break ;;
	esac
done
APPEND_VERB=""
[[ " ${MKOSI_ARGS[*]-} " == *" $VERB "* ]] || APPEND_VERB=1
case $VERB in
	build | shell | boot | vm | qemu | clean | burn)
		[[ $EUID -eq 0 ]] || die "'$VERB' must run as root (the sbctl db key is root-only): sudo $0 $VARIANT ${MKOSI_ARGS[*]-}"
		[[ -f $HERE/users.conf ]] || die "users.conf missing: cp users.conf.example users.conf and add your ssh keys"
		;;
esac

# The same version goes into the output names and, for the network variant,
# into the netroot URL, so it must be fixed here instead of letting mkosi run
# ./mkosi.version twice.
VERSION=$("$HERE/mkosi.version")
EXTRA=(--profile="$VARIANT" --image-version="$VERSION")

if [[ $VARIANT == network ]]; then
	if ((${#URLS[@]} == 0)); then
		# shellcheck source=/dev/null
		[[ -f $HERE/netboot.conf ]] && source "$HERE/netboot.conf"
		read -ra URLS <<<"${NETROOT_URL:-}"
	fi
	((${#URLS[@]})) || die "no netboot URL: pass --url http://SERVER/safespace/ or set NETROOT_URL in netboot.conf (see netboot.conf.example)"
	for url in "${URLS[@]}"; do
		[[ $url == http://* || $url == https://* ]] || die "netboot URL must start with http:// or https://: $url"
		host=${url#*//}; host=${host%%/*}; host=${host%%:*}
		[[ $host =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || $host =~ ^\[ ]] ||
			log "note: $host is a host name; the initrd resolves it from the DHCP lease (an IP address needs no DNS)"
		NETROOT+=("${url%/}/$VERSION/")
		EXTRA+=(--kernel-command-line="safespace.netroot=${url%/}/$VERSION/")
	done
fi

log "Running variant $VARIANT, version $VERSION"
((${#NETROOT[@]})) && log "netroot: ${NETROOT[*]}"
set -x
mkosi "${EXTRA[@]}" ${MKOSI_ARGS[@]+"${MKOSI_ARGS[@]}"} ${APPEND_VERB:+build}
{ set +x; } 2>/dev/null

[[ $VERB == build ]] || exit 0
log "Outputs in mkosi.output/ for safespace-arch-${VARIANT}_$VERSION"
if [[ $VARIANT == usb ]]; then
	log "Next: sudo ./burn.sh /dev/sdX   (then sudo ./diagnose.sh /dev/sdX)"
else
	log "Next: ./netboot-export.sh      (publishes the UKI and root images, see NETBOOT.md)"
fi
