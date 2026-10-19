#!/usr/bin/env bash
# The test suite: everything that can be checked without root, network or
# hardware. Run it after every change; it builds its own throwaway keys and
# fixtures in a temporary directory and touches nothing in the checkout.
#
#   tests/run.sh [--keep] [TEST...]
#
#   --keep   keep the temporary directory (printed at the end)
#   TEST     run only these (default: all): syntax groups keys builds
#            release server usb upload netroot dnsmasq nginx units
#
# Needs the build host's tools (README.md, "Build host"): sbsigntools,
# efitools, sbctl, cryptsetup, zstd, mtools, dosfstools, util-linux, binutils,
# openssl, rsync (rrsync), python, mkosi, dnsmasq, nginx, systemd. A test whose
# tool is missing is reported as SKIP, not as passed.
#
# What it does not cover (needs root or hardware, see AGENTS.md): a real
# mkosi build, server/setup.sh itself, the units running under systemd,
# booting in QEMU or on a machine.
set -Euo pipefail

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
KEEP=0 ONLY=()
for a in "$@"; do
	case $a in
		--keep) KEEP=1 ;;
		-h | --help) sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; exit 0 ;;
		*) ONLY+=("$a") ;;
	esac
done
W=$(mktemp -d "${TMPDIR:-/tmp}/safespace-tests.XXXXXX")
PIDS=()
finish() {
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	((KEEP)) && echo "kept: $W" || rm -rf "$W"
}
trap finish EXIT

PASS=0 FAIL=0 SKIP=0
pass() { printf '  \e[32mPASS\e[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \e[31mFAIL\e[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  \e[33mSKIP\e[0m %s\n' "$*"; SKIP=$((SKIP + 1)); }
check() { # DESCRIPTION COMMAND...: pass if the command succeeds
	local d=$1; shift
	if "$@" >"$W/last.log" 2>&1; then pass "$d"; else fail "$d"; sed 's/^/       /' "$W/last.log" | tail -5; fi
}
refuse() { # DESCRIPTION COMMAND...: pass if the command fails
	local d=$1; shift
	if "$@" >"$W/last.log" 2>&1; then fail "$d (was accepted)"; else pass "$d"; fi
}
need() { # TOOL...: all present, else SKIP the current test
	local t
	for t in "$@"; do command -v "$t" >/dev/null || { skip "$CURRENT: '$t' not installed"; return 1; }; done
}
wanted() { ((${#ONLY[@]} == 0)) || [[ " ${ONLY[*]} " == *" $1 "* ]]; }
section() { CURRENT=$1; printf '\e[1m== %s\e[0m\n' "$1"; }
port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
serve() { # DIR PORT: a static HTTP server in the background
	python3 -I -m http.server "$2" --bind 127.0.0.1 --directory "$1" >>"$W/http-$2.log" 2>&1 &
	PIDS+=($!)
	sleep 0.4
}

# shellcheck source=lib/fixtures.sh
source "$REPO/tests/lib/fixtures.sh"
log() { :; }
die() { echo "DIE: $*" >&2; return 1; }

# Shared fixtures: a key set, a checkout with one network and one usb build.
fixtures() {
	[[ -d $W/keys ]] && return 0
	need sbctl sbsign sbverify veritysetup zstd objcopy mcopy mkfs.vfat sfdisk openssl || return 1
	fx_keys "$W/keys" || { fail "creating throwaway sbctl keys"; return 1; }
	KD=$W/keys/keys
	CO=$W/checkout
	fx_checkout "$CO" "$REPO"
	cp "$KD/db/db.pem" "$CO/mkosi.extra/usr/share/safespace/secureboot/db.pem"
	NETPORT=$(port)
	# Two network builds of different group sets (the older one with the
	# desktop), one usb build.
	fx_network_build "$CO" 20990101-0000 "http://127.0.0.1:$NETPORT/network/" "$KD" base,remotedesktop \
		linux=6.1 vim=9.0 xfce4=4.18
	fx_network_build "$CO" 20990101-0100 "http://127.0.0.1:$NETPORT/network/" "$KD" base \
		linux=6.2 vim=9.0 openssh=9.9
	fx_usb_build "$CO" 20990101-0000 "$KD" base
	SHARE=$W/share STATE=$W/state
	mkdir -p "$SHARE/network" "$SHARE/usb" "$STATE"
	cat >"$W/server.conf" <<-EOF
		SHARE=$SHARE
		STATE=$STATE
		DB_CERT=$KD/db/db.pem
		SERVER_URL=http://127.0.0.1:$NETPORT
		DHCP_MODE=off
		DHCP_INTERFACE=lo
		DHCP_PROXY_SUBNET=127.0.0.0
		DHCP_RANGE=10.0.0.100,10.0.0.199,12h
		DHCP_ROUTER=10.0.0.1
		DHCP_DNS=10.0.0.1
	EOF
	chmod 0644 "$W/server.conf"
	export SAFESPACE_SERVER_CONF=$W/server.conf
}
NB=$REPO/server/safespace-netboot
# The share with both releases, for the tests that do not test releasing.
shared() {
	fixtures || return 1
	[[ -f $SHARE/network/release ]] || "$CO/release.sh" network --push "$SHARE" >/dev/null 2>&1 || { fail "releasing into the share"; return 1; }
	[[ -f $SHARE/usb/release ]] || "$CO/release.sh" usb --push "$SHARE" >/dev/null 2>&1 || { fail "releasing usb into the share"; return 1; }
}

# --- syntax --------------------------------------------------------------------------------
if wanted syntax; then
	section syntax
	while IFS= read -r f; do
		head -1 "$f" | grep -q '^#!/bin/sh' && check "sh -n $f" sh -n "$f" || check "bash -n ${f#"$REPO"/}" bash -n "$f"
	done < <(cd "$REPO" && find . -path ./mkosi.output -prune -o -path ./mkosi.cache -prune -o -path ./.git -prune -o \
		-type f \( -name '*.sh' -o -name 'mkosi.postinst' -o -name 'mkosi.finalize' -o -name 'mkosi.postoutput' \
		-o -name netroot -o -name usb-bootdev -o -name safespace-seal -o -name safespace-netboot -o -name load-docker-images \) -print |
		sed "s|^\.|$REPO|")
fi

# --- groups ----------------------------------------------------------------------------------
if wanted groups; then
	section groups
	t_groups() { # LIST EXPECTED
		(source "$REPO/lib/groups.sh"; groups_parse "$1" && [[ "${SAFESPACE_GROUPS[*]}" == "$2" ]])
	}
	check "default is base" t_groups base "base"
	check "case-insensitive, deduplicated, base first" t_groups "RemoteDesktop,docker,BASE,docker" "base remotedesktop docker"
	refuse "unknown group refused" t_groups "base,foo" ""
	refuse "shell characters refused" t_groups 'base;rm' ""
	if need mkosi; then
		pk() { mkosi --directory "$REPO" --profile=network "$@" --json summary 2>/dev/null |
			python3 -I -c 'import json, sys; print(" ".join(json.load(sys.stdin)["Images"][-1]["Packages"]))'; }
		base=$(pk) all=$(pk --profile=remotedesktop --profile=docker)
		check "base has no desktop and no docker" bash -c '[[ " $1 " != *" xfce4 "* && " $1 " != *" docker "* && " $1 " == *" openssh "* ]]' _ "$base"
		check "remotedesktop + docker add theirs" bash -c '[[ " $1 " == *" xfce4 "* && " $1 " == *" docker "* && " $1 " == *" tigervnc "* ]]' _ "$all"
	fi
fi

# --- keys ------------------------------------------------------------------------------------
if wanted keys && fixtures && need cert-to-efi-sig-list sign-efi-sig-list; then
	section keys
	printf '{"Images":[{"SecureBoot":true,"SecureBootKey":"/var/lib/sbctl/keys/db/db.key","SecureBootCertificate":"/var/lib/sbctl/keys/db/db.pem","SignExpectedPcrKey":"/x/pcr.key","SignExpectedPcrCertificate":"/x/pcr.crt","Environment":{"SAFESPACE_SBCTL_CONFIG":"%s"}}]}' \
		"$W/keys/sbctl.conf" >"$W/summary.json"
	t_export() (
		set -e
		source "$REPO/lib/keys.sh"
		keys_load "$W/summary.json"
		[[ $KEYS_DEDICATED == 1 && $(keys_mkosi_args | head -1) == "--secure-boot-key=$KD/db/db.key" ]]
		keys_export "$W/export"
	)
	check "dedicated sbctl key set: load and export" t_export
	check "export holds exactly the public files" bash -c '[[ $(ls "$1" | tr "\n" " ") == "db-append.auth db.auth db.pem GUID KEK-append.auth KEK.auth KEK.pem PK.auth PK.pem " ]]' _ "$W/export"
	refuse "no private key in the export" grep -rq 'PRIVATE KEY' "$W/export"
	ac() { [[ $(python3 -I "$REPO/tests/lib/authcheck.py" "$W/export/$1.auth" "$2" "$KD/$3/$3.pem") == *"['$4']" ]]; }
	check "PK.auth replaces (signed by PK)" ac PK PK PK 0x27
	check "KEK.auth replaces, KEK-append.auth appends" bash -c "$(declare -f ac); W=$W REPO=$REPO KD=$KD; ac KEK KEK PK 0x27 && ac KEK-append KEK PK 0x67"
	check "db.auth replaces, db-append.auth appends (signed by KEK)" bash -c "$(declare -f ac); W=$W REPO=$REPO KD=$KD; ac db db KEK 0x27 && ac db-append db KEK 0x67"
	cp -r "$W/keys" "$W/keys-yk"
	sed -i "s|$W/keys|$W/keys-yk|g" "$W/keys-yk/sbctl.conf"
	chmod u+w "$W/keys-yk/keys/db/db.key"
	echo '{"yubikey": "9c"}' >"$W/keys-yk/keys/db/db.key"
	sed "s|$W/keys/sbctl.conf|$W/keys-yk/sbctl.conf|" "$W/summary.json" >"$W/summary-yk.json"
	refuse "a key that is no key file (YubiKey) is refused" bash -c "source '$REPO/lib/keys.sh'; die() { exit 1; }; keys_load '$W/summary-yk.json'"
fi

# --- builds on the build host ----------------------------------------------------------------
if wanted builds && fixtures; then
	section builds
	BS=$CO/build.sh
	"$BS" list >"$W/list.txt" 2>&1
	check "list: every build, one group set after the other" bash -c '[[ $(grep -Eo "(network|usb) +[a-z-]+_[0-9-]+" "$1" | tr -s " " | tr "\n" "|") == "network base-remotedesktop_20990101-0000|network base_20990101-0100|usb base_20990101-0000|" ]]' _ "$W/list.txt"
	check "list: snapshot and package count" grep -q "base_20990101-0100 .*2099/01/01 .* 3 " "$W/list.txt"
	check "show: details and packages" bash -c '"$1" show base_20990101-0100 | grep -q "^commit *abc1234" && "$1" show base_20990101-0100 | grep -q "openssh *9.9"' _ "$BS"
	refuse "show: an ambiguous or unknown build is refused" "$BS" show base_20990101-9999
	"$BS" diff base-remotedesktop_20990101-0000 base_20990101-0100 >"$W/diff.txt" 2>&1
	check "diff: added, removed, upgraded" bash -c 'grep -q "^+ openssh" "$1" && grep -q "^- xfce4" "$1" && grep -q "^~ linux .*6.1 -> 6.2" "$1" && grep -q "1 packages unchanged" "$1"' _ "$W/diff.txt"
	if need rsync; then
		mkdir -p "$W/pick/network" "$W/pick/usb"
		"$CO/release.sh" network --groups Base,RemoteDesktop --push "$W/pick" >"$W/pick.log" 2>&1
		check "release --groups picks the newest build of that set" grep -q "^BUILD=base-remotedesktop_20990101-0000$" "$W/pick/network/release"
		check "... and warns about the newer unreleased build" grep -q "a newer build is not released: base_20990101-0100" "$W/pick.log"
		check "... and records the push in released.log" grep -q " $W/pick$" "$CO/mkosi.output/network/base-remotedesktop_20990101-0000/released.log"
		check "the release carries build, built, snapshot, commit, packages" bash -c 'grep -q "^BUILT=2099-01-01T00:00" $1 && grep -q "^SNAPSHOT=2099/01/01" $1 && grep -q "^COMMIT=abc1234$" $1 && grep -q "^PACKAGES=3$" $1' _ "$W/pick/network/release"
		check "release without a choice takes the newest build" bash -c '"$1" network >/dev/null 2>&1 && grep -q "^BUILD=base_20990101-0100$" "$2/release"' _ "$CO/release.sh" "$CO/mkosi.release/network"
		check "release --build an older one (going back)" bash -c '"$1" network --build base-remotedesktop_20990101-0000 >/dev/null 2>&1 && grep -q "^BUILD=base-remotedesktop_20990101-0000$" "$2/release"' _ "$CO/release.sh" "$CO/mkosi.release/network"
		refuse "release --groups without such a build is refused" "$CO/release.sh" network --groups base,docker
	fi
	# prune: four more base builds, the oldest of them released last to a target.
	P=$W/prunetest
	fx_checkout "$P" "$REPO"
	for v in 0100 0200 0300 0400 0500; do mkdir -p "$P/mkosi.output/network/base_20990101-$v"; fx_finish "$P" network base "20990101-$v" a=1 >/dev/null; done
	mkdir -p "$P/mkosi.output/network/base-docker_20990101-0000"; fx_finish "$P" network base,docker 20990101-0000 a=1 >/dev/null
	echo "2099-01-01T02:00:00+00:00 dist1" >"$P/mkosi.output/network/base_20990101-0100/released.log"
	mkdir -p "$P/mkosi.output/network/base_20990101-0600" "$P/mkosi.output/network/base_20990101-0010"
	touch -d '-1 day' "$P/mkosi.output/network/base_20990101-0010"
	check "prune --keep 3 --yes" "$P/build.sh" prune --keep 3 --yes
	check "prune: 3 newest per group set + the last released one stay" bash -c '[[ $(LC_ALL=C ls "$1" | tr "\n" " ") == "base-docker_20990101-0000 base_20990101-0100 base_20990101-0300 base_20990101-0400 base_20990101-0500 base_20990101-0600 " ]]' _ "$P/mkosi.output/network"
fi

# --- release ---------------------------------------------------------------------------------
if wanted release && fixtures && need rsync; then
	section release
	check "release.sh network stages and passes its own checks" "$CO/release.sh" network --groups base,remotedesktop
	check "staged: fixed names, groups recorded" bash -c '[[ -f $1/boot.efi && -f $1/root.img && -f $1/root.verity && $(grep ^GROUPS= $1/release) == GROUPS=base,remotedesktop ]]' _ "$CO/mkosi.release/network"
	check "release.sh network --push into a share" "$CO/release.sh" network --push "$SHARE"
	check "release.sh usb --push into a share" "$CO/release.sh" usb --push "$SHARE"
	check "the share serves the newest release" bash -c '[[ $(grep ^BUILD= $1/network/release) == BUILD=base_20990101-0100 ]]' _ "$SHARE"
	check "server status shows build, groups, snapshot" bash -c '"$1" status | grep -q "groups base, built 2099-01-01T01:00:00+00:00, snapshot 2099/01/01, commit abc1234, 3 packages"' _ "$NB"
fi

# --- server: verify ------------------------------------------------------------------------
if wanted server && shared; then
	section server
	check "verify: the served network release is ok" "$NB" verify network
	check "status says ok" bash -c '"$1" status | grep -A2 "^network" | grep -q "ok, checked"' _ "$NB"
	check "verify --changed skips an unchanged release" bash -c '[[ -z $("$1" verify --changed network) ]]' _ "$NB"
	cp -a "$SHARE/network" "$W/network.good"
	tamper() { # NAME COMMAND: tamper with a copy of the good release, expect BROKEN
		rm -rf "$SHARE/network"
		cp -a "$W/network.good" "$SHARE/network"
		bash -c "$2" _ "$SHARE/network"
		refuse "verify detects: $1" "$NB" verify network
	}
	tamper "a manipulated hash tree (SHA256SUMS recomputed)" 'printf "\xff" | dd of=$1/root.verity bs=1 seek=8192 conv=notrunc status=none; source '"$REPO"'/tests/lib/fixtures.sh; fx_resum $1'
	tamper "a manipulated root image" 'printf "\xff" | dd of=$1/root.img bs=1 seek=4096 conv=notrunc status=none; source '"$REPO"'/tests/lib/fixtures.sh; fx_resum $1'
	tamper "a UKI signed by another key" 'sbattach --remove $1/boot.efi >/dev/null; sbsign --key '"$W"'/keys/keys/KEK/KEK.key --cert '"$W"'/keys/keys/KEK/KEK.pem --output $1/boot.efi $1/boot.efi >/dev/null 2>&1; source '"$REPO"'/tests/lib/fixtures.sh; fx_resum $1'
	tamper "an unsigned UKI" 'sbattach --remove $1/boot.efi >/dev/null; source '"$REPO"'/tests/lib/fixtures.sh; fx_resum $1'
	tamper "a roothash that is not the signed one" 'echo 0000000000000000000000000000000000000000000000000000000000000000 >$1/roothash; source '"$REPO"'/tests/lib/fixtures.sh; fx_resum $1'
	tamper "a file not in SHA256SUMS" 'echo x >$1/extra'
	tamper "a broken transfer" 'truncate -s 1M $1/root.img'
	check "status says BROKEN" bash -c '"$1" status | grep -A2 "^network" | grep -q BROKEN' _ "$NB"
	check "verify never changes the share (the broken file is still there)" bash -c '[[ $(stat -c %s "$1/network/root.img") == 1048576 ]]' _ "$SHARE"
	rm -rf "$SHARE/network"
	cp -a "$W/network.good" "$SHARE/network"
fi

# --- usb release ----------------------------------------------------------------------------
if wanted usb && shared; then
	section usb
	check "verify: the served usb release is ok" "$NB" verify usb
	cp -a "$SHARE/usb" "$W/usb.good"
	zstd -dqf "$SHARE/usb/image.raw.zst" -o "$W/usb.raw"
	printf '\xff' | dd of="$W/usb.raw" bs=1 seek=$((18432 * 512 + 4096)) conv=notrunc status=none
	zstd -qf "$W/usb.raw" -o "$SHARE/usb/image.raw.zst"
	fx_resum "$SHARE/usb"
	refuse "verify detects a manipulated root partition in the image" "$NB" verify usb
	rm -rf "$SHARE/usb" "$W/usb.raw"
	cp -a "$W/usb.good" "$SHARE/usb"
fi

# --- upload through rrsync ------------------------------------------------------------------
if wanted upload && fixtures && need rsync rrsync; then
	section upload
	# rrsync runs the server's rsync by its absolute path.
	[[ -x /usr/bin/rsync ]] || { skip "upload: rrsync needs /usr/bin/rsync"; ONLY_SKIP=1; }
fi
if wanted upload && fixtures && [[ -z ${ONLY_SKIP:-} ]] && command -v rrsync >/dev/null; then
	# ssh replaced by a script that runs what the server's authorized_keys
	# forces: rrsync confined to the share, write-only, no delete.
	cat >"$W/fake-ssh" <<-EOF
		#!/bin/sh
		shift; while [ "\$1" != rsync ] && [ \$# -gt 0 ]; do shift; done
		SSH_ORIGINAL_COMMAND="\$*" exec $(command -v rrsync) -wo -no-del -munge "$W/rshare"
	EOF
	chmod +x "$W/fake-ssh"
	mkdir -p "$W/rshare/network" "$W/rshare/usb"
	up() { RSYNC_RSH="$W/fake-ssh" "$CO/release.sh" network --push "safespace@server"; }
	check "upload through rrsync" up
	check "a second upload replaces the release" up
	check "uploaded files arrived" bash -c 'cmp -s "$1/rshare/network/root.img" "$2/mkosi.release/network/root.img"' _ "$W" "$CO"
	mkdir -p "$W/empty"
	refuse "rrsync refuses deleting" env RSYNC_RSH="$W/fake-ssh" rsync -r --delete "$W/empty/" "safespace@server:network/"
	check "... and the release is still there" test -f "$W/rshare/network/root.img"
	refuse "rrsync refuses reading" env RSYNC_RSH="$W/fake-ssh" rsync -r "safespace@server:network/" "$W/readback/"
	refuse "rrsync refuses paths outside the share" env RSYNC_RSH="$W/fake-ssh" rsync "$W/server.conf" "safespace@server:../escape"
	check "nothing escaped the share" test ! -e "$W/escape"
fi

# --- netroot (initrd) -------------------------------------------------------------------------
if wanted netroot && shared && need curl; then
	section netroot
	NR=$REPO/mkosi.initrd.conf/mkosi.profiles/network/mkosi.extra/usr/local/lib/safespace/netroot
	S=$W/shims
	mkdir -p "$S"
	for c in modprobe udevadm umount sleep; do printf '#!/bin/sh\nexit 0\n' >"$S/$c"; done
	printf '#!/bin/sh\necho /dev/loop9\n' >"$S/losetup"
	printf '#!/bin/sh\nshift $(($# - 1)); mkdir -p "$1"\n' >"$S/mount"
	printf '#!/bin/sh\necho "$*" >>"%s/systemctl.calls"\n' "$W" >"$S/systemctl"
	printf '#!/bin/sh\necho "$*" >>"%s/veritysetup.calls"\n[ -f "%s/veritysetup.fail" ] && exit 1\nexit 0\n' "$W" "$W" >"$S/veritysetup"
	chmod +x "$S"/*
	served=$(tr -d '[:space:]' <"$SHARE/network/roothash")
	mkdir -p "$W/old/network" && echo 1111111111111111111111111111111111111111111111111111111111111111 >"$W/old/network/roothash"
	cp "$SHARE/network/root.img" "$SHARE/network/root.verity" "$W/old/network/"
	P1=$(port) P2=$(port)
	serve "$W/old" "$P1"
	serve "$SHARE" "$P2"
	nr() { # ROOTHASH URL...: run netroot against the servers
		local h=$1; shift
		rm -f "$W/systemctl.calls" "$W/veritysetup.calls"
		NETROOT_CMDLINE="roothash=$h $(printf 'safespace.netroot=%s ' "$@")" NETROOT_DIR=$W/nr PATH="$S:$PATH" sh "$NR" >/dev/null 2>&1
		return 0
	}
	nr "$served" "http://127.0.0.1:$P2/network/"
	check "the matching release is opened with the signed root hash" grep -q "$served" "$W/veritysetup.calls"
	check "... and no reboot" test ! -e "$W/systemctl.calls"
	: >"$W/http-$P1.log"
	nr "$served" "http://127.0.0.1:$P1/network/"
	check "only another release served: reboot to load the new boot.efi" grep -qx reboot "$W/systemctl.calls"
	check "... without downloading the root image" bash -c '! grep -q "GET /network/root.img" "$1"' _ "$W/http-$P1.log"
	nr "$served" "http://127.0.0.1:$P1/network/" "http://127.0.0.1:$P2/network/"
	check "a stale first server and a matching second one: no reboot" test ! -e "$W/systemctl.calls"
	check "... the second one is used" grep -q "$served" "$W/veritysetup.calls"
	touch "$W/veritysetup.fail"
	nr "$served" "http://127.0.0.1:$P2/network/"
	check "the right release but a refused image: an error, no reboot loop" test ! -e "$W/systemctl.calls"
	rm -f "$W/veritysetup.fail"
fi

# --- dnsmasq ----------------------------------------------------------------------------------
if wanted dnsmasq && shared && need dnsmasq; then
	section dnsmasq
	for m in proxy dhcp; do
		sed -i "s/^DHCP_MODE=.*/DHCP_MODE=$m/" "$W/server.conf"
		check "DHCP_MODE=$m: configuration passes dnsmasq --test" bash -c 'RUNTIME_DIRECTORY=$2 "$1" dnsmasq-config && dnsmasq --test -C "$2/dnsmasq.conf"' _ "$NB" "$W/run-$m"
	done
	check "HTTP boot URL is \$SERVER_URL/network/boot.efi" grep -q "^dhcp-boot=tag:httpclient,http://127.0.0.1:$NETPORT/network/boot.efi$" "$W/run-dhcp/dnsmasq.conf"
	sed -i "s/^DHCP_MODE=.*/DHCP_MODE=off/" "$W/server.conf"
	refuse "DHCP_MODE=off writes no configuration" env RUNTIME_DIRECTORY="$W/run-off" "$NB" dnsmasq-config
fi

# --- nginx ------------------------------------------------------------------------------------
if wanted nginx && shared && need nginx curl; then
	section nginx
	N=$W/nginx P=$(port)
	mkdir -p "$N/logs" "$N/tmp"
	echo x >"$SHARE/network/.hidden"
	sed -e "s|@SHARE@|$SHARE|g" -e "s/listen      80 default_server;/listen 127.0.0.1:$P;/" -e '/\[::\]:80/d' "$REPO/server/nginx/safespace.conf" >"$N/site.conf"
	cat >"$N/nginx.conf" <<-EOF
		pid $N/nginx.pid; error_log $N/logs/error.log; events {}
		http { access_log $N/logs/access.log; client_body_temp_path $N/tmp; proxy_temp_path $N/tmp; fastcgi_temp_path $N/tmp;
		       uwsgi_temp_path $N/tmp; scgi_temp_path $N/tmp; include $N/site.conf; }
	EOF
	if nginx -p "$N" -c "$N/nginx.conf" -e "$N/logs/error.log" 2>"$W/nginx.err"; then
		sleep 0.3
		code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
		check "boot.efi is served with Content-Length" bash -c 'curl -sI "$1" | grep -qi "^content-length: [1-9]"' _ "http://127.0.0.1:$P/safespace/network/boot.efi"
		check "usb image is served" test "$(code -I "http://127.0.0.1:$P/safespace/usb/image.raw.zst")" = 200
		check "hidden files are refused" test "$(code "http://127.0.0.1:$P/safespace/network/.hidden")" = 403
		check "no directory listing" test "$(code "http://127.0.0.1:$P/safespace/network/")" = 403
		check "nothing outside /safespace/" test "$(code "http://127.0.0.1:$P/etc/passwd")" = 404
		check "no writing" test "$(code -X PUT --data x "http://127.0.0.1:$P/safespace/network/x")" = 403
		kill "$(cat "$N/nginx.pid")"
	else
		fail "nginx did not start: $(head -1 "$W/nginx.err")"
	fi
	rm -f "$SHARE/network/.hidden"
fi

# --- units ------------------------------------------------------------------------------------
if wanted units && need systemd-analyze; then
	section units
	U=$W/units
	mkdir -p "$U"
	for f in "$REPO"/server/systemd/*; do
		sed -e "s|@SHARE@|/srv/safespace/share|g" -e "s|@DNSMASQ@|/usr/bin/dnsmasq|" \
			-e "s|/usr/local/bin/safespace-netboot|$NB|" "$f" >"$U/$(basename "$f")"
	done
	check "server units pass systemd-analyze verify" bash -c '[[ -z $(systemd-analyze verify "$1"/* 2>&1) ]]' _ "$U"
	check "verify service sandbox: exposure below 2" bash -c 'systemd-analyze security --offline=yes "$1/safespace-netboot-verify.service" 2>/dev/null | grep -Eq "Overall exposure level.*: [01]\."' _ "$U"
fi

printf '\n\e[1m%d passed, %d failed, %d skipped\e[0m\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0))
