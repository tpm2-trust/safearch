#!/usr/bin/env bash
# The test suite: everything that can be checked without root, network or
# hardware. Run it after every change; it builds its own throwaway keys and
# fixtures in a temporary directory and touches nothing in the checkout.
#
#   tests/run.sh [--keep] [TEST...]
#
#   --keep   keep the temporary directory (printed at the end)
#   TEST     run only these (default: all): syntax groups keys builds
#            release server stick upload netroot initrd combined dnsmasq nginx
#            units
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

# Shared fixtures: a key set, a checkout with two builds of different group
# sets (the older one with the desktop); each serves sticks and network boot.
fixtures() {
	[[ -d $W/keys ]] && return 0
	need sbctl sbsign sbverify veritysetup zstd objcopy mcopy mkfs.vfat sfdisk openssl || return 1
	fx_keys "$W/keys" || { fail "creating throwaway sbctl keys"; return 1; }
	KD=$W/keys/keys
	CO=$W/checkout
	fx_checkout "$CO" "$REPO"
	cp "$KD/db/db.pem" "$CO/mkosi.extra/usr/share/safespace/secureboot/db.pem"
	NETPORT=$(port)
	fx_build "$CO" 20990101-0000 "$KD" base,remotedesktop "http://127.0.0.1:$NETPORT/" \
		linux=6.1 vim=9.0 xfce4=4.18 || { fail "building the fixture"; return 1; }
	fx_build "$CO" 20990101-0100 "$KD" base "http://127.0.0.1:$NETPORT/" \
		linux=6.2 vim=9.0 openssh=9.9 || { fail "building the fixture"; return 1; }
	B=$CO/mkosi.output/base_20990101-0100
	SHARE=$W/share STATE=$W/state
	mkdir -p "$SHARE" "$STATE"
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
# The share with the newest build released, for the tests that do not test releasing.
shared() {
	fixtures || return 1
	[[ -f $SHARE/release ]] || "$CO/release.sh" --push "$SHARE" >/dev/null 2>&1 || { fail "releasing into the share"; return 1; }
}

# --- syntax --------------------------------------------------------------------------------
if wanted syntax; then
	section syntax
	while IFS= read -r f; do
		head -1 "$f" | grep -q '^#!/bin/sh' && check "sh -n $f" sh -n "$f" || check "bash -n ${f#"$REPO"/}" bash -n "$f"
	done < <(cd "$REPO" && find . -path ./mkosi.output -prune -o -path ./mkosi.cache -prune -o -path ./.git -prune -o \
		-type f \( -name '*.sh' -o -name 'mkosi.postinst' -o -name 'mkosi.finalize' -o -name 'mkosi.postoutput' \
		-o -name netroot -o -name usb-bootdev -o -name select -o -name safespace-seal -o -name safespace-select -o -name safespace-netboot -o -name load-docker-images \) -print |
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
	check "build.sh: --combined is gone (the whole stack is the default)" \
		bash -c '"$1" --combined 2>&1 | grep -q "no --combined any more"' _ "$REPO/build.sh"
	if need mkosi; then
		pk() { mkosi --directory "$REPO" "$@" --json summary 2>/dev/null |
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
	check "finalize: a build keeps exactly its parts, no disk image, no initrd copy" bash -c '[[ $(LC_ALL=C ls "$1" | tr "\n" " ") == "boot.efi build.json layout.sfdisk manifest.json root.img root.verity roothash systemd-boot.efi systemd-stub.efi " ]]' _ "$B"
	BS=$CO/build.sh
	"$BS" list >"$W/list.txt" 2>&1
	check "list: every build, one group set after the other" bash -c '[[ $(grep -Eo "^[a-z-]+_[0-9-]+" "$1" | tr "\n" "|") == "base-remotedesktop_20990101-0000|base_20990101-0100|" ]]' _ "$W/list.txt"
	check "list: snapshot and package count" grep -q "base_20990101-0100 .*2099/01/01 .* 3 " "$W/list.txt"
	check "show: details and packages" bash -c '"$1" show base_20990101-0100 | grep -q "^commit *abc1234" && "$1" show base_20990101-0100 | grep -q "openssh *9.9"' _ "$BS"
	refuse "show: an unknown build is refused" "$BS" show base_20990101-9999
	refuse "build.sh refuses the old variant argument" "$BS" usb
	"$BS" diff base-remotedesktop_20990101-0000 base_20990101-0100 >"$W/diff.txt" 2>&1
	check "diff: added, removed, upgraded" bash -c 'grep -q "^+ openssh" "$1" && grep -q "^- xfce4" "$1" && grep -q "^~ linux .*6.1 -> 6.2" "$1" && grep -q "1 packages unchanged" "$1"' _ "$W/diff.txt"
	if need rsync; then
		mkdir -p "$W/pick"
		"$CO/release.sh" --groups Base,RemoteDesktop --push "$W/pick" >"$W/pick.log" 2>&1
		check "release --groups picks the newest build of that set" grep -q "^BUILD=base-remotedesktop_20990101-0000$" "$W/pick/release"
		check "... and warns about the newer unreleased build" grep -q "a newer build is not released: base_20990101-0100" "$W/pick.log"
		check "... and records the push in released.log" grep -q " $W/pick$" "$CO/mkosi.output/base-remotedesktop_20990101-0000/released.log"
		check "the release carries build, built, snapshot, commit, packages" bash -c 'grep -q "^BUILT=2099-01-01T00:00" $1 && grep -q "^SNAPSHOT=2099/01/01" $1 && grep -q "^COMMIT=abc1234$" $1 && grep -q "^PACKAGES=3$" $1' _ "$W/pick/release"
		check "release without a choice takes the newest build" bash -c '"$1" >/dev/null 2>&1 && grep -q "^BUILD=base_20990101-0100$" "$2/release"' _ "$CO/release.sh" "$CO/mkosi.release"
		check "release --build an older one (going back)" bash -c '"$1" --build base-remotedesktop_20990101-0000 >/dev/null 2>&1 && grep -q "^BUILD=base-remotedesktop_20990101-0000$" "$2/release"' _ "$CO/release.sh" "$CO/mkosi.release"
		refuse "release --groups without such a build is refused" "$CO/release.sh" --groups base,docker
		check "staged as hardlinks of the build (nothing copied)" bash -c '[[ $(stat -c %i "$1/root.img") == $(stat -c %i "$2/root.img") ]]' _ "$CO/mkosi.release" "$CO/mkosi.output/base-remotedesktop_20990101-0000"
	fi
	# prune: four more base builds, the oldest of them released last to a target.
	P=$W/prunetest
	fx_checkout "$P" "$REPO"
	for v in 0100 0200 0300 0400 0500; do fx_finish "$P" base "20990101-$v" a=1 >/dev/null; done
	fx_finish "$P" base,docker 20990101-0000 a=1 >/dev/null
	echo "2099-01-01T02:00:00+00:00 dist1" >"$P/mkosi.output/base_20990101-0100/released.log"
	mkdir -p "$P/mkosi.output/base_20990101-0600" "$P/mkosi.output/base_20990101-0010"
	touch -d '-1 day' "$P/mkosi.output/base_20990101-0010"
	check "prune --keep 3 --yes" "$P/build.sh" prune --keep 3 --yes
	check "prune: 3 newest per group set + the last released one stay" bash -c '[[ $(LC_ALL=C ls "$1" | tr "\n" " ") == "base-docker_20990101-0000 base_20990101-0100 base_20990101-0300 base_20990101-0400 base_20990101-0500 base_20990101-0600 " ]]' _ "$P/mkosi.output"
fi

# --- release ---------------------------------------------------------------------------------
if wanted release && fixtures && need rsync; then
	section release
	check "release.sh stages and passes its own checks" "$CO/release.sh" --groups base,remotedesktop
	check "staged: all parts, groups recorded" bash -c 'for f in boot.efi root.img root.verity roothash systemd-boot.efi layout.sfdisk manifest.json cmdline release SHA256SUMS; do [[ -f $1/$f ]] || exit 1; done; [[ $(grep ^GROUPS= $1/release) == GROUPS=base,remotedesktop ]]' _ "$CO/mkosi.release"
	check "release.sh --push into a share" "$CO/release.sh" --push "$SHARE"
	check "the share serves the newest release" bash -c '[[ $(grep ^BUILD= $1/release) == BUILD=base_20990101-0100 ]]' _ "$SHARE"
	check "server status shows build, groups, snapshot" bash -c '"$1" status | grep -q "groups base, built 2099-01-01T01:00:00+00:00, snapshot 2099/01/01, commit abc1234, 3 packages"' _ "$NB"
fi

# --- server: verify ------------------------------------------------------------------------
if wanted server && shared; then
	section server
	check "verify: the served release is ok" "$NB" verify
	check "status says ok" bash -c '"$1" status | grep -q "ok, checked"' _ "$NB"
	check "verify --changed skips an unchanged release" bash -c '[[ -z $("$1" verify --changed) ]]' _ "$NB"
	cp -a "$SHARE" "$W/share.good"
	tamper() { # NAME COMMAND: tamper with a copy of the good release, expect BROKEN
		rm -rf "$SHARE"
		cp -a "$W/share.good" "$SHARE"
		bash -c "$2" _ "$SHARE"
		refuse "verify detects: $1" "$NB" verify
	}
	resum="source $REPO/tests/lib/fixtures.sh; fx_resum \$1"
	tamper "a manipulated hash tree (SHA256SUMS recomputed)" 'printf "\xff" | dd of=$1/root.verity bs=1 seek=8192 conv=notrunc status=none; '"$resum"
	tamper "a manipulated root image" 'printf "\xff" | dd of=$1/root.img bs=1 seek=4096 conv=notrunc status=none; '"$resum"
	tamper "a UKI signed by another key" 'sbattach --remove $1/boot.efi >/dev/null; sbsign --key '"$KD"'/KEK/KEK.key --cert '"$KD"'/KEK/KEK.pem --output $1/boot.efi $1/boot.efi >/dev/null 2>&1; '"$resum"
	tamper "an unsigned UKI" 'sbattach --remove $1/boot.efi >/dev/null; '"$resum"
	tamper "systemd-boot signed by another key" 'sbattach --remove $1/systemd-boot.efi >/dev/null; sbsign --key '"$KD"'/KEK/KEK.key --cert '"$KD"'/KEK/KEK.pem --output $1/systemd-boot.efi $1/systemd-boot.efi >/dev/null 2>&1; '"$resum"
	tamper "a roothash that is not the signed one" 'echo 0000000000000000000000000000000000000000000000000000000000000000 >$1/roothash; '"$resum"
	tamper "a partition table with another root partition UUID" 'sed -i "/4F68BCE3/s/uuid=[0-9A-F-]*/uuid=11111111-2222-3333-4444-555555555555/" $1/layout.sfdisk; '"$resum"
	tamper "a partition too small for the root image" 'sed -i "/4F68BCE3/s/size= *[0-9]*/size=8/" $1/layout.sfdisk; '"$resum"
	tamper "a file not in SHA256SUMS" 'echo x >$1/extra'
	tamper "a broken transfer" 'truncate -s 1M $1/root.img'
	check "status says BROKEN" bash -c '"$1" status | grep -q BROKEN' _ "$NB"
	check "verify never changes the share (the broken file is still there)" bash -c '[[ $(stat -c %s "$1/root.img") == 1048576 ]]' _ "$SHARE"
	rm -rf "$SHARE"
	cp -a "$W/share.good" "$SHARE"
fi

# --- writing a stick (burn.sh --image, lib/stick.sh) -----------------------------------------
if wanted stick && shared && need mkfs.fat mmd mcopy sfdisk; then
	section stick
	cut_part() { # IMAGE TYPE OUT: a partition of a stick image into a file
		set -- "$1" "$(awk -F'[=,]' -v t="$2" 'toupper($0) ~ "TYPE=" t { gsub(/ /, ""); print $2, $4; exit }' "$B/layout.sfdisk")" "$3"
		dd if="$1" of="$3" bs=512 skip="${2% *}" count="${2#* }" status=none
	}
	stick_ok() { # IMAGE: the written stick is the build
		local img=$1
		[[ $(sfdisk -d "$img" | sed -e '/^device:/d' -e 's|^[^ ]* : ||') == "$(cat "$B/layout.sfdisk")" ]] || { echo "partition table differs"; return 1; }
		[[ $(mdir -b -/ -i "$img@@$((2048 * 512))" ::/ | sort | tr '\n' ' ') == "::/EFI/ ::/EFI/BOOT/ ::/EFI/BOOT/BOOTX64.EFI ::/EFI/Linux/ ::/EFI/Linux/safespace-arch.efi " ]] || { echo "ESP content differs"; return 1; }
		mcopy -n -i "$img@@$((2048 * 512))" ::/EFI/BOOT/BOOTX64.EFI "$W/st.boot" && cmp -s "$W/st.boot" "$B/systemd-boot.efi" || { echo "BOOTX64.EFI differs"; return 1; }
		mcopy -n -i "$img@@$((2048 * 512))" ::/EFI/Linux/safespace-arch.efi "$W/st.uki" && cmp -s "$W/st.uki" "$B/boot.efi" || { echo "UKI differs"; return 1; }
		[[ $(od -An -tu2 -j$((2048 * 512 + 11)) -N2 "$img" | tr -d ' ') == 512 ]] || { echo "FAT sector size is not 512"; return 1; }
		cut_part "$img" 4F68BCE3 "$W/st.root" && cut_part "$img" 2C7357ED "$W/st.verity" &&
			veritysetup verify "$W/st.root" "$W/st.verity" "$(cat "$B/roothash")" || { echo "root does not verify"; return 1; }
	}
	check "burn.sh --image from a build" "$CO/burn.sh" base_20990101-0100 --image "$W/stick1.raw"
	check "... is the build: table, ESP, signed files, root block by block" stick_ok "$W/stick1.raw"
	check "burn.sh --image from a share directory (SHA256SUMS checked)" "$CO/burn.sh" "$SHARE" --image "$W/stick2.raw"
	SP=$(port)
	serve "$SHARE" "$SP"
	check "burn.sh --image from a server URL (root streamed)" "$CO/burn.sh" "http://127.0.0.1:$SP/" --image "$W/stick3.raw"
	check "... is the build too" stick_ok "$W/stick3.raw"
	cp "$SHARE/root.img" "$W/root.good"
	printf '\xff' | dd of="$SHARE/root.img" bs=1 seek=4096 conv=notrunc status=none
	refuse "a root.img that does not match SHA256SUMS is refused while streaming" "$CO/burn.sh" "http://127.0.0.1:$SP/" --image "$W/stick4.raw"
	check "... and nothing is left behind" test ! -e "$W/stick4.raw"
	cp "$W/root.good" "$SHARE/root.img"
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
	mkdir -p "$W/rshare" "$W/empty"
	up() { RSYNC_RSH="$W/fake-ssh" "$CO/release.sh" --push "safespace@server"; }
	check "upload through rrsync" up
	check "a second upload replaces the release" up
	check "uploaded files arrived" bash -c 'cmp -s "$1/rshare/root.img" "$2/mkosi.release/root.img"' _ "$W" "$CO"
	refuse "rrsync refuses deleting" env RSYNC_RSH="$W/fake-ssh" rsync -r --delete "$W/empty/" "safespace@server:"
	check "... and the release is still there" test -f "$W/rshare/root.img"
	refuse "rrsync refuses reading" env RSYNC_RSH="$W/fake-ssh" rsync -r "safespace@server:" "$W/readback/"
	refuse "rrsync refuses paths outside the share" env RSYNC_RSH="$W/fake-ssh" rsync "$W/server.conf" "safespace@server:../escape"
	check "nothing escaped the share" test ! -e "$W/escape"
fi

# --- netroot (initrd, the network path) ---------------------------------------------------------
if wanted netroot && shared && need curl; then
	section netroot
	NR=$REPO/mkosi.initrd.conf/mkosi.extra/usr/local/lib/safespace/netroot
	S=$W/shims
	mkdir -p "$S"
	for c in modprobe udevadm umount sleep; do printf '#!/bin/sh\nexit 0\n' >"$S/$c"; done
	printf '#!/bin/sh\necho /dev/loop9\n' >"$S/losetup"
	printf '#!/bin/sh\nshift $(($# - 1)); mkdir -p "$1"\n' >"$S/mount"
	printf '#!/bin/sh\necho "$*" >>"%s/systemctl.calls"\n' "$W" >"$S/systemctl"
	printf '#!/bin/sh\necho "$*" >>"%s/veritysetup.calls"\n[ -f "%s/veritysetup.fail" ] && exit 1\nexit 0\n' "$W" "$W" >"$S/veritysetup"
	chmod +x "$S"/*
	served=$(tr -d '[:space:]' <"$SHARE/roothash")
	mkdir -p "$W/old" && echo 1111111111111111111111111111111111111111111111111111111111111111 >"$W/old/roothash"
	cp "$SHARE/root.img" "$SHARE/root.verity" "$W/old/"
	P1=$(port) P2=$(port)
	serve "$W/old" "$P1"
	serve "$SHARE" "$P2"
	nr() { # ROOTHASH URL...: run netroot against the servers
		local h=$1; shift
		rm -f "$W/systemctl.calls" "$W/veritysetup.calls"
		NETROOT_CMDLINE="roothash=$h $(printf 'safespace.netroot=%s ' "$@")" NETROOT_DIR=$W/nr PATH="$S:$PATH" sh "$NR" >/dev/null 2>&1
		return 0
	}
	nr "$served" "http://127.0.0.1:$P2/"
	check "the matching release is opened with the signed root hash" grep -q "$served" "$W/veritysetup.calls"
	check "... and no reboot" test ! -e "$W/systemctl.calls"
	: >"$W/http-$P1.log"
	nr "$served" "http://127.0.0.1:$P1/"
	check "only another release served: reboot to load the new boot.efi" grep -qx reboot "$W/systemctl.calls"
	check "... without downloading the root image" bash -c '! grep -q "GET /root.img" "$1"' _ "$W/http-$P1.log"
	nr "$served" "http://127.0.0.1:$P1/" "http://127.0.0.1:$P2/"
	check "a stale first server and a matching second one: no reboot" test ! -e "$W/systemctl.calls"
	check "... the second one is used" grep -q "$served" "$W/veritysetup.calls"
	touch "$W/veritysetup.fail"
	nr "$served" "http://127.0.0.1:$P2/"
	check "the right release but a refused image: an error, no reboot loop" test ! -e "$W/systemctl.calls"
	rm -f "$W/veritysetup.fail"
fi

# --- initrd: the scripts only call what the initrd has ------------------------------------
# Against the initrd of the newest real build here (SKIP without one): its
# first archive holds the programs. Catches e.g. a grep in a script, which the
# initrd does not have.
if wanted initrd; then
	section initrd
	uki=$(ls -t "$REPO"/mkosi.output/*/boot.efi 2>/dev/null | head -1 || true)
	if [[ -z $uki ]]; then
		skip "initrd: no build in mkosi.output/ to compare with"
	elif need objcopy zstd cpio; then
		objcopy -O binary --only-section=.initrd "$uki" "$W/initrd.img"
		zstd -dc "$W/initrd.img" 2>/dev/null | cpio -t 2>/dev/null >"$W/initrd.list" || true
		IS=$REPO/mkosi.initrd.conf/mkosi.extra/usr/local/lib/safespace
		for f in usb-bootdev netroot; do
			# with select, which both source
			cat "$IS/select" "$IS/$f" >"$W/initrd.$f"
			missing=$(python3 -I "$REPO/tests/lib/shcmds.py" "$W/initrd.$f" | while IFS= read -r c; do
				if [[ $c == /* ]]; then grep -qxF "${c#/}" "$W/initrd.list" || echo "$c"
				else grep -qE "^(usr/)?s?bin/$c$" "$W/initrd.list" || echo "$c"; fi
			done | tr '\n' ' ')
			check "$f (+ select) calls only programs in the initrd ($(basename "$(dirname "$uki")"))${missing:+: missing $missing}" test -z "$missing"
		done
	fi
fi

# --- combined: several group sets in one build, selected at boot -------------------------
# Two fixture builds with the same kernel, composed as build.sh does without --groups
# (lib/compose.sh, real ukify with throwaway keys), released, written to a stick,
# and the initrd's choice of the root (select, efivars in a directory).
if wanted combined && fixtures && need ukify openssl; then
	section combined
	t_combos() { # CONF EXPECTED
		(die() { exit 1; }; source "$REPO/lib/groups.sh"; source "$REPO/lib/compose.sh"
		printf '%s\n' "$1" >"$W/combos.conf"; combos_load "$W/combos.conf" && [[ "${COMBO_NAMES[*]}|${COMBO_GROUPS[*]}" == "$2" ]])
	}
	check "combinations.conf of the repository" t_combos "$(cat "$REPO/combinations.conf")" "base docker|base base,docker"
	refuse "base=base must come first" t_combos $'docker=base,docker\nbase=base' ""
	refuse "a name twice" t_combos $'base=base\nx=docker\nx=docker' ""
	refuse "an invalid name" t_combos $'base=base\nX;y=docker' ""
	refuse "an unknown group" t_combos $'base=base\nx=foo' ""

	CV=20990102-0000 PCO=$W/cparts CCO=$W/ccombined
	fx_checkout "$PCO" "$REPO"
	fx_checkout "$CCO" "$REPO"
	cp "$KD/db/db.pem" "$CCO/mkosi.extra/usr/share/safespace/secureboot/db.pem"
	CP=$(port)
	fx_build "$PCO" "$CV" "$KD" base "http://127.0.0.1:$CP/" linux=6.2 vim=9.0 &&
		fx_build "$PCO" "$CV" "$KD" base,docker "http://127.0.0.1:$CP/" linux=6.2 vim=9.0 docker=28 ||
		fail "building the combination fixtures"
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=pcr/ -keyout "$W/pcr.key" -out "$W/pcr.crt" 2>/dev/null
	t_compose() ( # under build.sh's shell options
		set -Eeuo pipefail
		die() { echo "DIE: $*" >&2; exit 1; }
		HERE=$CCO; source "$CCO/lib/groups.sh"; source "$CCO/lib/builds.sh"; source "$CCO/lib/compose.sh"
		combos_load "$REPO/combinations.conf"
		KEYS_SB_DIR=$KD KEYS_PCR_KEY=$W/pcr.key KEYS_PCR_CERT=$W/pcr.crt
		compose_build "$CCO/mkosi.output/combined_$CV" "$PCO/mkosi.output/base_$CV" "$PCO/mkosi.output/base-docker_$CV"
		builds_write_info "$CCO/mkosi.output/combined_$CV" build="combined_$CV" version="$CV" groups=combined \
				combinations=base:base,docker:base+docker started=2099-01-02T00:00:00+00:00 finished=2099-01-02T00:00:00+00:00 \
				snapshot=2099/01/02 mirror=default commit=abc1234 uncommitted_changes=no signer=test builder=test
	)
	C=$CCO/mkosi.output/combined_$CV
	# Not inside check: bash ignores set -e in a condition.
	t_compose >"$W/compose.log" 2>&1
	check "compose: one UKI for base and docker (ukify, the image's stub)" test $? -eq 0
	check "... signed by the db key" sbverify --cert "$KD/db/db.pem" "$C/boot.efi"
	ccmd=$(objcopy -O binary --only-section=.cmdline "$C/boot.efi" /dev/stdout 2>/dev/null | tr -d '\0')
	hb=$(cat "$C/roothash-base" 2>/dev/null) hd=$(cat "$C/roothash-docker" 2>/dev/null)
	check "... its command line names both roots, without roothash=" \
		bash -c '[[ " $1 " == *" safespace.root.base=$2 safespace.root.docker=$3 "* && " $1 " != *" roothash="* && " $1 " == *" safespace.netroot="* ]]' _ "$ccmd" "$hb" "$hd"
	check "... with signed expected PCRs (.pcrsig)" bash -c 'objdump -h "$1" | grep -q "\.pcrsig"' _ "$C/boot.efi"
	check "... the kernel and initrd of base" bash -c 'cmp -s <(objcopy -O binary --only-section=.initrd "$1" /dev/stdout) <(objcopy -O binary --only-section=.initrd "$2" /dev/stdout)' _ "$C/boot.efi" "$PCO/mkosi.output/base_$CV/boot.efi"
	CS=$W/cstage
	check "release.sh --groups combined stages and verifies it" "$CCO/release.sh" --groups combined --stage "$CS"
	check "... release names the combinations" grep -qx COMBINATIONS=base,docker "$CS/release"
	check "... all parts, no single root" bash -c 'cd "$1" && ls root-base.img root-base.verity roothash-base manifest-base.json root-docker.img root-docker.verity roothash-docker manifest-docker.json >/dev/null && [[ ! -e root.img ]]' _ "$CS"
	t_verify() (source "$REPO/lib/verify.sh"; verify_release "$1" "$KD/db/db.pem" >/dev/null 2>&1)
	rm -rf "$W/ctamper" && cp -a "$CS" "$W/ctamper"
	printf '\xff' | dd of="$W/ctamper/root-docker.img" bs=1 seek=4096 conv=notrunc status=none
	fx_resum "$W/ctamper"
	refuse "a changed root-docker.img (sums recomputed) is refused" t_verify "$W/ctamper"
	rm -rf "$W/ctamper" && cp -a "$CS" "$W/ctamper"
	sed -i 's/^COMBINATIONS=.*/COMBINATIONS=base/' "$W/ctamper/release"
	fx_resum "$W/ctamper"
	refuse "COMBINATIONS= that differs from the signed command line is refused" t_verify "$W/ctamper"

	if need mkfs.fat mmd mcopy sfdisk; then
		check "burn.sh --image from the combined release" "$CCO/burn.sh" "$CS" --image "$W/cstick.raw"
		t_cstick() { # IMAGE: every root and hash tree in its partition, named and verified
			local img=$1 f start size n
			[[ $(sfdisk -d "$img" | grep -c 'type=') == 5 ]] || { echo "not 5 partitions"; return 1; }
			for n in base docker; do
				sfdisk -d "$img" | grep -q "name=\"root-$n\"" || { echo "no root-$n"; return 1; }
			done
			while read -r f start size; do
				dd if="$img" of="$W/cst.$f" bs=512 skip="$start" count="$size" status=none
			done < <(awk -F', *' '/name="root-/ { for (i = 1; i <= NF; i++) { split($i, kv, "="); k = kv[1]; v = kv[2]; gsub(/[ "]/, "", k); gsub(/[ "]/, "", v); if (k ~ /start$/) s = v; if (k == "size") z = v; if (k == "name") nm = v }
				f = nm ~ /-verity$/ ? substr(nm, 1, length(nm) - 7) ".verity" : nm ".img"; print f, s, z }' <(sfdisk -d "$img"))
			for n in base docker; do
				veritysetup verify "$W/cst.root-$n.img" "$W/cst.root-$n.verity" "$(cat "$CS/roothash-$n")" || { echo "root-$n does not verify"; return 1; }
			done
		}
		check "... both roots on the stick, each verifying against its signed hash" t_cstick "$W/cstick.raw"
		CSP=$CP
		serve "$CS" "$CSP"
		check "burn.sh --image from a server URL (every root streamed, sums checked)" "$CCO/burn.sh" "http://127.0.0.1:$CSP/" --image "$W/cstick2.raw"
		check "... both roots on it too" t_cstick "$W/cstick2.raw"
	fi

	# The initrd's choice of the root.
	SEL=$REPO/mkosi.initrd.conf/mkosi.extra/usr/local/lib/safespace/select
	SG=8a3e6c1d-4b2f-4e9a-b7d5-1c0f9e2a6b34 EV=$W/efivars
	H1=$(printf '1%.0s' {1..64}) H2=$(printf '2%.0s' {1..64})
	CL="ro safespace.root.base=$H1 safespace.root.docker=$H2"
	t_select() { # CMDLINE ONCE PERSISTENT EXPECTED("name:hash")
		rm -rf "$EV" && mkdir -p "$EV"
		[[ -z $2 ]] || printf '\x07\x00\x00\x00%s' "$2" >"$EV/SafespaceSelectOnce-$SG"
		[[ -z $3 ]] || printf '\x07\x00\x00\x00%s' "$3" >"$EV/SafespaceSelect-$SG"
		local got
		got=$(cmdline=$1 SAFESPACE_EFIVARS=$EV sh -c 'msg() { :; }; . "$0"; select_root || exit 1; echo "$SELECT_NAME:$SELECT_HASH"' "$SEL") || return 1
		[[ $got == "$4" ]] || { echo "got $got"; return 1; }
	}
	check "select: nothing set boots base" t_select "$CL" "" "" "base:$H1"
	check "select: SafespaceSelect=docker" t_select "$CL" "" docker "docker:$H2"
	check "select: SafespaceSelectOnce wins over SafespaceSelect" t_select "$CL" base docker "base:$H1"
	check "... and is deleted" test ! -e "$EV/SafespaceSelectOnce-$SG"
	check "select: safespace.select= on the command line wins" t_select "$CL safespace.select=docker" base "" "docker:$H2"
	refuse "select: an unknown name stops the boot" t_select "$CL" "" nope ""
	check "select: a variable that is no name is ignored" t_select "$CL" "" 'x;rm' "base:$H1"
	check "select: a single build uses roothash=" t_select "ro roothash=$H1" "" docker ":$H1"

	# netroot loads the selected combination's files.
	if [[ -n ${S:-} && -d ${S:-/nonexistent} ]] && [[ -n ${CSP:-} ]]; then
		NR=$REPO/mkosi.initrd.conf/mkosi.extra/usr/local/lib/safespace/netroot
		rm -rf "$EV" && mkdir -p "$EV" && printf '\x07\x00\x00\x00docker' >"$EV/SafespaceSelect-$SG"
		rm -f "$W/veritysetup.calls" "$W/systemctl.calls" && : >"$W/http-$CSP.log"
		NETROOT_CMDLINE="$ccmd" NETROOT_DIR=$W/cnr SAFESPACE_EFIVARS=$EV PATH="$S:$PATH" sh "$NR" >/dev/null 2>&1 || true
		check "netroot: SafespaceSelect=docker opens docker's root with its signed hash" grep -q "$hd" "$W/veritysetup.calls"
		check "... downloads root-docker.img, not base's" bash -c 'grep -q "GET /root-docker.img" "$1" && ! grep -q "GET /root-base.img" "$1"' _ "$W/http-$CSP.log"
		check "... no reboot" test ! -e "$W/systemctl.calls"
	else
		skip "netroot with a combination: needs the netroot and stick sections"
	fi
fi

# --- dnsmasq ----------------------------------------------------------------------------------
if wanted dnsmasq && shared && need dnsmasq; then
	section dnsmasq
	for m in proxy dhcp; do
		sed -i "s/^DHCP_MODE=.*/DHCP_MODE=$m/" "$W/server.conf"
		check "DHCP_MODE=$m: configuration passes dnsmasq --test" bash -c 'RUNTIME_DIRECTORY=$2 "$1" dnsmasq-config && dnsmasq --test -C "$2/dnsmasq.conf"' _ "$NB" "$W/run-$m"
	done
	check "HTTP boot URL is \$SERVER_URL/boot.efi" grep -q "^dhcp-boot=tag:httpclient,http://127.0.0.1:$NETPORT/boot.efi$" "$W/run-dhcp/dnsmasq.conf"
	check "PXE boot file is boot.efi under the TFTP root (the share)" grep -q "^dhcp-boot=tag:efi64,boot.efi$" "$W/run-dhcp/dnsmasq.conf"
	# A real TFTP download from the generated proxy configuration, in an unprivileged
	# network namespace (DHCP_INTERFACE=lo there): catches option combinations that
	# pass --test but send nothing (bind-interfaces + tftp-single-port).
	if ! command -v unshare ip curl >/dev/null 2>&1 || ! unshare -rn true 2>/dev/null; then
		skip "TFTP download: needs unshare (user namespaces), ip and curl"
	else
		check "TFTP serves boot.efi (proxy configuration, network namespace)" unshare -rn bash -c '
			ip link set lo up
			dnsmasq -k -C "$1/dnsmasq.conf" --user=root --group= --pid-file= --dhcp-leasefile="$1/leases" --log-facility="$1/dnsmasq.log" &
			p=$!; trap "kill $p" EXIT; sleep 0.5
			n=$(timeout 20 curl -s -o /dev/null -w "%{size_download}" tftp://127.0.0.1/boot.efi)
			test "$n" = "$(stat -c %s "$2/boot.efi")"' _ "$W/run-proxy" "$SHARE"
	fi
	sed -i "s/^DHCP_MODE=.*/DHCP_MODE=off/" "$W/server.conf"
	refuse "DHCP_MODE=off writes no configuration" env RUNTIME_DIRECTORY="$W/run-off" "$NB" dnsmasq-config
fi

# --- nginx ------------------------------------------------------------------------------------
if wanted nginx && shared && need nginx curl; then
	section nginx
	N=$W/nginx P=$(port)
	mkdir -p "$N/logs" "$N/tmp"
	echo x >"$SHARE/.hidden"
	sed -e "s|@SHARE@|$SHARE|g" -e "s/listen      80 default_server;/listen 127.0.0.1:$P;/" -e '/\[::\]:80/d' "$REPO/server/nginx/safespace.conf" >"$N/site.conf"
	cat >"$N/nginx.conf" <<-EOF
		pid $N/nginx.pid; error_log $N/logs/error.log; events {}
		http { access_log $N/logs/access.log; client_body_temp_path $N/tmp; proxy_temp_path $N/tmp; fastcgi_temp_path $N/tmp;
		       uwsgi_temp_path $N/tmp; scgi_temp_path $N/tmp; include $N/site.conf; }
	EOF
	if nginx -p "$N" -c "$N/nginx.conf" -e "$N/logs/error.log" 2>"$W/nginx.err"; then
		sleep 0.3
		code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
		check "boot.efi is served with Content-Length" bash -c 'curl -sI "$1" | grep -qi "^content-length: [1-9]"' _ "http://127.0.0.1:$P/safespace/boot.efi"
		check "the stick parts are served" test "$(code -I "http://127.0.0.1:$P/safespace/layout.sfdisk")" = 200
		check "hidden files are refused" test "$(code "http://127.0.0.1:$P/safespace/.hidden")" = 403
		check "no directory listing" test "$(code "http://127.0.0.1:$P/safespace/")" = 403
		check "nothing outside /safespace/" test "$(code "http://127.0.0.1:$P/etc/passwd")" = 404
		check "no writing" test "$(code -X PUT --data x "http://127.0.0.1:$P/safespace/x")" = 403
		kill "$(cat "$N/nginx.pid")"
	else
		fail "nginx did not start: $(head -1 "$W/nginx.err")"
	fi
	rm -f "$SHARE/.hidden"
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
	I=$REPO/mkosi.initrd.conf/mkosi.extra/usr/lib/systemd/system
	V=/sys/firmware/efi/efivars/LoaderDevicePartUUID-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
	check "initrd: the stick path runs only when started from a partition" grep -qx "ConditionPathExists=$V" "$I/usb-bootdev.service"
	check "initrd: the network path runs only when not" grep -qx "ConditionPathExists=!$V" "$I/netroot.service"
	check "initrd: both paths are enabled" test -L "$I/initrd.target.wants/usb-bootdev.service" -a -L "$I/initrd.target.wants/netroot.service"
fi

printf '\n\e[1m%d passed, %d failed, %d skipped\e[0m\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0))
