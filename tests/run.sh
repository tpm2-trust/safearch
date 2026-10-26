#!/usr/bin/env bash
# The test suite: everything that can be checked without root, network or
# hardware. Run it after every change; it builds its own throwaway keys and
# fixtures in a temporary directory and touches nothing in the checkout.
#
#   tests/run.sh [--keep] [TEST...]
#
#   --keep   keep the temporary directory (printed at the end)
#   TEST     run only these (default: all): syntax groups keys builds
#            release server stick upload netroot initrd compose dnsmasq nginx
#            assh units
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

# Shared fixtures: a key set, a checkout with two builds as build.sh composes
# them (the older one with a desktop combination, the newer one with containers);
# each serves sticks and network boot.
fixtures() {
	[[ -d $W/keys ]] && return 0
	need sbctl sbsign sbverify veritysetup zstd cpio objcopy objdump mcopy mkfs.vfat sfdisk openssl ukify || return 1
	fx_keys "$W/keys" || { fail "creating throwaway sbctl keys"; return 1; }
	KD=$W/keys/keys
	CO=$W/checkout
	fx_checkout "$CO" "$REPO"
	cp "$KD/db/db.pem" "$CO/mkosi.extra/usr/share/safespace/secureboot/db.pem"
	NETPORT=$(port)
	fx_build "$CO" 20990101-0000 "$KD" "http://127.0.0.1:$NETPORT/" \
		root base "linux=6.1 vim=9.0" \
		remotedesktop base,xfce4-headless-vnc "linux=6.1 vim=9.0 xfce4=4.18" >"$W/fixture.log" 2>&1 &&
		fx_build "$CO" 20990101-0100 "$KD" "http://127.0.0.1:$NETPORT/" \
			root base "linux=6.2 vim=9.0 openssh=9.9" \
			containers base,docker "linux=6.2 docker=28" >>"$W/fixture.log" 2>&1 ||
		{ fail "building the fixture"; sed 's/^/       /' "$W/fixture.log" | tail -5; return 1; }
	B=$CO/mkosi.output/combined_20990101-0100
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

# --- groups and combinations -----------------------------------------------------------------
if wanted groups; then
	section groups
	t_groups() { # LIST EXPECTED
		(source "$REPO/lib/groups.sh"; groups_parse "$1" && [[ "${SAFESPACE_GROUPS[*]}" == "$2" ]])
	}
	check "default is base" t_groups base "base"
	check "case-insensitive, deduplicated, base first" t_groups "Docker,xfce4-headless-vnc,BASE,docker" "base docker xfce4-headless-vnc"
	refuse "unknown group refused" t_groups "base,foo" ""
	refuse "shell characters refused" t_groups 'base;rm' ""
	check "every group but base has its profile" bash -c 'source "$1/lib/groups.sh"; for g in "${GROUPS_KNOWN[@]}"; do [[ $g == base || -f $1/mkosi.profiles/$g/mkosi.conf ]] || exit 1; done' _ "$REPO"
	# debug is a standard group only as long as it adds packages and nothing else.
	check "group debug: a package list only (no other setting, no files)" bash -c '
		[[ $(ls -A "$1/mkosi.profiles/debug") == mkosi.conf ]] &&
		[[ -z $(grep -v "^[[:space:]]*#" "$1/mkosi.profiles/debug/mkosi.conf" | grep . | grep -vx "\[Content\]" | grep -vx "Packages=" | grep -v "^[[:space:]]\+[a-z0-9][a-z0-9.+_-]*$") ]] &&
		! grep -rhw debug "$1/mkosi.postinst" "$1/mkosi.finalize" "$1/mkosi.postoutput" "$1/mkosi.conf" "$1/mkosi.extra" "$1/mkosi.initrd.conf" | grep -qv "^[[:space:]]*#"' _ "$REPO"
	t_combos() { # CONF EXPECTED
		(die() { exit 1; }; source "$REPO/lib/groups.sh"; source "$REPO/lib/compose.sh"
		printf '%s\n' "$1" >"$W/combos.conf"; combos_load "$W/combos.conf" && [[ "${COMBO_NAMES[*]}|${COMBO_GROUPS[*]}" == "$2" ]])
	}
	check "combinations.conf of the repository" t_combos "$(cat "$REPO/combinations.conf")" \
		"root containers|base base,docker"
	check "tests/vm.combinations.conf (the test build's)" t_combos "$(cat "$REPO/tests/vm.combinations.conf")" "root containers debug|base base,docker base,debug"
	check "any combination may come first (it is the default)" t_combos $'x=docker\ny=base' "x y|base,docker base"
	refuse "a name twice" t_combos $'base=base\nx=docker\nx=docker' ""
	refuse "an invalid name" t_combos $'base=base\nX;y=docker' ""
	refuse "a name too long for its partition names" t_combos 'abcdefghijklmnopqrstuvwxy=base' ""
	refuse "an unknown group" t_combos $'base=base\nx=foo' ""
	refuse "no combination" t_combos '# nothing' ""
	for a in "--groups base" --debug --combined "--version 1" summary shell; do
		check "build.sh: '$a' is refused (combinations.conf decides, build.sh only builds)" \
			bash -c '! "$1" $2 >"$3" 2>&1 && grep -Eq "combinations.conf decides|only builds" "$3"' _ "$REPO/build.sh" "$a" "$W/refused.log"
	done
	if need mkosi; then
		pk() { mkosi --directory "$REPO" "$@" --json summary 2>/dev/null |
			python3 -I -c 'import json, sys; print(" ".join(json.load(sys.stdin)["Images"][-1]["Packages"]))'; }
		base=$(pk) all=$(pk --profile=xfce4-headless-vnc --profile=docker) dbg=$(pk --profile=debug)
		check "base: no desktop, no docker, no debug tools; btrfs-progs" bash -c '[[ " $1 " != *" xfce4 "* && " $1 " != *" docker "* && " $1 " != *" tcpdump "* && " $1 " == *" openssh "* && " $1 " == *" btrfs-progs "* ]]' _ "$base"
		check "xfce4-headless-vnc + docker add theirs" bash -c '[[ " $1 " == *" xfce4 "* && " $1 " == *" docker "* && " $1 " == *" tigervnc "* ]]' _ "$all"
		check "debug adds its tools" bash -c '[[ " $1 " == *" tcpdump "* && " $1 " == *" kexec-tools "* && " $1 " != *" docker "* ]]' _ "$dbg"
		check "firmware by package: Intel, AMD GPU, Realtek, both microcodes; no meta package, nothing else" bash -c '
			for p in linux-firmware-intel linux-firmware-amdgpu linux-firmware-realtek intel-ucode amd-ucode; do [[ " $1 " == *" $p "* ]] || exit 1; done
			! tr " " "\n" <<<"$1" | grep -E "^linux-firmware(-|$)" | grep -vxE "linux-firmware-(intel|amdgpu|realtek)" | grep -q .' _ "$all $dbg"
		# Smaller roots: the filters as mkosi itself evaluates them (mkosi.kmod).
		mkosi --directory "$REPO" --json summary >"$W/summary-slim.json" 2>/dev/null
		check "root modules: no Wi-Fi, Bluetooth, NVIDIA; NICs, docker, storage, DRM stay" python3 -I -c '
import json, sys
sys.path[:0] = [p for p in sys.argv[2:]]
from mkosi.kmod import globs_match_module, globs_match_firmware
i = json.load(open(sys.argv[1]))["Images"][-1]
km, fw = i["KernelModules"], i["FirmwareFiles"]
gone = ["kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi", "kernel/net/mac80211/mac80211",
        "kernel/net/wireless/cfg80211", "kernel/drivers/bluetooth/btusb", "kernel/net/bluetooth/bluetooth",
        "kernel/drivers/gpu/drm/nouveau/nouveau", "kernel/drivers/gpu/nova-core/nova_core",
        "kernel/drivers/staging/rtl8723bs/r8723bs", "kernel/net/batman-adv/batman-adv"]
kept = ["kernel/drivers/net/ethernet/realtek/r8169", "kernel/drivers/net/ethernet/intel/e1000e/e1000e",
        "kernel/fs/overlayfs/overlay", "kernel/net/bridge/br_netfilter", "kernel/drivers/net/veth",
        "kernel/drivers/gpu/drm/amd/amdgpu/amdgpu", "kernel/drivers/gpu/drm/i915/i915", "kernel/fs/btrfs/btrfs"]
bad = [m for m in gone if globs_match_module(m, km)] + [m for m in kept if not globs_match_module(m, km)]
bad += [f for f in ["rtl_nic/rtl8168h-2.fw", "amdgpu/navi10_sos.bin"] if not globs_match_firmware(f, fw, match_default=True)]
sys.exit(print("wrong:", bad) if bad else 0)' "$W/summary-slim.json" "$(python3 -I -c 'import mkosi, os; print(os.path.dirname(os.path.dirname(mkosi.__file__)))')"
		check "root: no headers, docs, man pages; locales en_US only" bash -c '
			python3 -I -c "import json, sys; r = json.load(open(sys.argv[1]))[\"Images\"][-1][\"RemoveFiles\"]
sys.exit(not {\"/usr/include\", \"/usr/share/doc\", \"/usr/share/man\", \"/usr/share/info\"} <= set(r))" "$1" &&
			grep -q "^find \"\$BUILDROOT/usr/share/locale\" .* ! -name en ! -name en_US -exec rm -rf" "$2/mkosi.postinst"' _ "$W/summary-slim.json" "$REPO"
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
	fx_part "$W/part" 20990102-0000 "$KD" "" linux=1 >/dev/null 2>&1
	check "finalize: a combination keeps exactly its parts, no disk image, no initrd copy" bash -c '[[ $(LC_ALL=C ls "$1" | tr "\n" " ") == "boot.efi layout.sfdisk manifest.json root.img root.verity roothash systemd-boot.efi systemd-stub.efi " ]]' _ "$W/part"
	check "a build: one UKI, one pair per combination, nothing else" bash -c '[[ $(LC_ALL=C ls "$1" | tr "\n" " ") == "boot.efi build.json layout.sfdisk manifest-containers.json manifest-root.json root-containers.img root-containers.verity root-root.img root-root.verity roothash-containers roothash-root systemd-boot.efi " ]]' _ "$B"
	BS=$CO/build.sh
	"$BS" list >"$W/list.txt" 2>&1
	check "list: every build, oldest first" bash -c '[[ $(grep -Eo "^combined_[0-9-]+" "$1" | tr "\n" "|") == "combined_20990101-0000|combined_20990101-0100|" ]]' _ "$W/list.txt"
	check "list: snapshot and package count (all combinations)" grep -q "combined_20990101-0100 .*2099/01/01 .* 5 " "$W/list.txt"
	check "show: details and packages per combination" bash -c '"$1" show combined_20990101-0100 >"$2" && grep -q "^commit *abc1234" "$2" && grep -q "^containers (base,docker): 2 packages" "$2" && grep -q "openssh *9.9" "$2"' _ "$BS" "$W/show.txt"
	refuse "show: an unknown build is refused" "$BS" show combined_20990101-9999
	"$BS" diff combined_20990101-0000 combined_20990101-0100 >"$W/diff.txt" 2>&1
	check "diff per combination: added, upgraded, combinations only in one" bash -c 'grep -q "^root:" "$1" && grep -q "^  + openssh" "$1" && grep -q "^  ~ linux .*6.1 -> 6.2" "$1" && grep -q "1 packages unchanged" "$1" && grep -q "^remotedesktop: only in the first build" "$1" && grep -q "^containers: only in the second build" "$1"' _ "$W/diff.txt"
	if need rsync; then
		mkdir -p "$W/pick"
		"$CO/release.sh" --build combined_20990101-0000 --push "$W/pick" >"$W/pick.log" 2>&1
		check "release --build picks that build" grep -q "^BUILD=combined_20990101-0000$" "$W/pick/release"
		check "... and warns about the newer unreleased build" grep -q "a newer build is not released: combined_20990101-0100" "$W/pick.log"
		check "... and records the push in released.log" grep -q " $W/pick$" "$CO/mkosi.output/combined_20990101-0000/released.log"
		check "the release carries build, combinations, built, snapshot, commit, packages" bash -c 'grep -q "^COMBINATIONS=root,remotedesktop$" $1 && grep -q "^BUILT=2099-01-01T00:00" $1 && grep -q "^SNAPSHOT=2099/01/01" $1 && grep -q "^COMMIT=abc1234$" $1 && grep -q "^PACKAGES=5$" $1' _ "$W/pick/release"
		check "release without a choice takes the newest build" bash -c '"$1" >/dev/null 2>&1 && grep -q "^BUILD=combined_20990101-0100$" "$2/release"' _ "$CO/release.sh" "$CO/mkosi.release"
		refuse "release --groups is gone" "$CO/release.sh" --groups base
		check "staged as hardlinks of the build (nothing copied)" bash -c '[[ $(stat -c %i "$1/root-root.img") == $(stat -c %i "$2/root-root.img") ]]' _ "$CO/mkosi.release" "$B"
	fi
	# prune: five builds, the oldest of them released last to a target.
	P=$W/prunetest
	fx_checkout "$P" "$REPO"
	for v in 0100 0200 0300 0400 0500; do fx_finish "$P" "20990101-$v" a=1 >/dev/null; done
	echo "2099-01-01T02:00:00+00:00 dist1" >"$P/mkosi.output/combined_20990101-0100/released.log"
	mkdir -p "$P/mkosi.output/combined_20990101-0600" "$P/mkosi.output/combined_20990101-0010"
	touch -d '-1 day' "$P/mkosi.output/combined_20990101-0010"
	check "prune --keep 3 --yes" "$P/build.sh" prune --keep 3 --yes
	check "prune: the 3 newest + the last released one stay (and a build still being written)" bash -c '[[ $(LC_ALL=C ls "$1" | tr "\n" " ") == "combined_20990101-0100 combined_20990101-0300 combined_20990101-0400 combined_20990101-0500 combined_20990101-0600 " ]]' _ "$P/mkosi.output"
fi

# --- release ---------------------------------------------------------------------------------
if wanted release && fixtures && need rsync; then
	section release
	check "release.sh stages and passes its own checks" "$CO/release.sh"
	check "staged: all parts, combinations recorded" bash -c 'for f in boot.efi systemd-boot.efi layout.sfdisk cmdline release SHA256SUMS root-root.img root-root.verity roothash-root manifest-root.json root-containers.img root-containers.verity roothash-containers manifest-containers.json; do [[ -f $1/$f ]] || exit 1; done; [[ $(grep ^COMBINATIONS= $1/release) == COMBINATIONS=root,containers ]]' _ "$CO/mkosi.release"
	check "release.sh --push into a share" "$CO/release.sh" --push "$SHARE"
	check "the share serves the newest release" bash -c '[[ $(grep ^BUILD= $1/release) == BUILD=combined_20990101-0100 ]]' _ "$SHARE"
	check "server status shows build, combinations, snapshot" bash -c '"$1" status | grep -q "combinations root,containers, built 2099-01-01T01:00:00+00:00, snapshot 2099/01/01, commit abc1234, 5 packages"' _ "$NB"
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
	tamper "a manipulated hash tree (SHA256SUMS recomputed)" 'printf "\xff" | dd of=$1/root-root.verity bs=1 seek=8192 conv=notrunc status=none; '"$resum"
	tamper "a manipulated root image" 'printf "\xff" | dd of=$1/root-root.img bs=1 seek=4096 conv=notrunc status=none; '"$resum"
	tamper "a manipulated root image of another combination" 'printf "\xff" | dd of=$1/root-containers.img bs=1 seek=4096 conv=notrunc status=none; '"$resum"
	tamper "a UKI signed by another key" 'sbattach --remove $1/boot.efi >/dev/null; sbsign --key '"$KD"'/KEK/KEK.key --cert '"$KD"'/KEK/KEK.pem --output $1/boot.efi $1/boot.efi >/dev/null 2>&1; '"$resum"
	tamper "an unsigned UKI" 'sbattach --remove $1/boot.efi >/dev/null; '"$resum"
	tamper "systemd-boot signed by another key" 'sbattach --remove $1/systemd-boot.efi >/dev/null; sbsign --key '"$KD"'/KEK/KEK.key --cert '"$KD"'/KEK/KEK.pem --output $1/systemd-boot.efi $1/systemd-boot.efi >/dev/null 2>&1; '"$resum"
	tamper "a roothash that is not the signed one" 'echo 0000000000000000000000000000000000000000000000000000000000000000 >$1/roothash-containers; '"$resum"
	tamper "COMBINATIONS= that differs from the signed command line" 'sed -i "s/^COMBINATIONS=.*/COMBINATIONS=root/" $1/release; '"$resum"
	# Validly signed by the db key, but not what a build makes:
	resign="source $REPO/tests/lib/fixtures.sh; fx_uki \$1/boot.efi \"\$2\" $KD/db/db.key $KD/db/db.pem; $resum"
	h=$(cat "$SHARE/roothash-root")
	tamper "a single-root UKI (roothash=, no safespace.root.*), signed by the db key" "set -- \$1 'roothash=$h systemd.volatile=state lockdown=integrity'; $resign"
	tamper "a UKI without lockdown=integrity, signed by the db key" "set -- \$1 'systemd.volatile=state $(grep -o 'safespace\.root\.[^ ]*' "$SHARE/cmdline" | tr '\n' ' ')'; $resign"
	tamper "a partition table with another root partition UUID" 'sed -i "/4F68BCE3/s/uuid=[0-9A-F-]*/uuid=11111111-2222-3333-4444-555555555555/" $1/layout.sfdisk; '"$resum"
	tamper "a partition too small for the root image" 'sed -i "/4F68BCE3/s/size= *[0-9]*/size=8/" $1/layout.sfdisk; '"$resum"
	tamper "a file not in SHA256SUMS" 'echo x >$1/extra'
	tamper "a broken transfer" 'truncate -s 1M $1/root-root.img'
	check "status says BROKEN" bash -c '"$1" status | grep -q BROKEN' _ "$NB"
	check "verify never changes the share (the broken file is still there)" bash -c '[[ $(stat -c %s "$1/root-root.img") == 1048576 ]]' _ "$SHARE"
	rm -rf "$SHARE"
	cp -a "$W/share.good" "$SHARE"
fi

# --- writing a stick (burn.sh --image, lib/stick.sh) -----------------------------------------
if wanted stick && shared && need mkfs.fat mmd mcopy sfdisk; then
	section stick
	cut_part() { # IMAGE PARTNAME OUT: a partition of a stick image into a file
		set -- "$1" "$(awk -F', *' -v pn="$2" '$0 ~ "name=\"" pn "\"" { for (i = 1; i <= NF; i++) { split($i, kv, "="); gsub(/[ "]/, "", kv[1]); gsub(/[ "]/, "", kv[2]); if (kv[1] ~ /start$/) s = kv[2]; if (kv[1] == "size") z = kv[2] } print s, z; exit }' "$B/layout.sfdisk")" "$3"
		dd if="$1" of="$3" bs=512 skip="${2% *}" count="${2#* }" status=none
	}
	stick_ok() { # IMAGE: the written stick is the build
		local img=$1 n
		[[ $(sfdisk -d "$img" | sed -e '/^device:/d' -e 's|^[^ ]* : ||') == "$(cat "$B/layout.sfdisk")" ]] || { echo "partition table differs"; return 1; }
		[[ $(sfdisk -d "$img" | grep -c 'type=') == 5 ]] || { echo "not 5 partitions"; return 1; }
		[[ $(mdir -b -/ -i "$img@@$((2048 * 512))" ::/ | sort | tr '\n' ' ') == "::/EFI/ ::/EFI/BOOT/ ::/EFI/BOOT/BOOTX64.EFI ::/EFI/Linux/ ::/EFI/Linux/safespace-arch.efi " ]] || { echo "ESP content differs"; return 1; }
		mcopy -n -i "$img@@$((2048 * 512))" ::/EFI/BOOT/BOOTX64.EFI "$W/st.boot" && cmp -s "$W/st.boot" "$B/systemd-boot.efi" || { echo "BOOTX64.EFI differs"; return 1; }
		mcopy -n -i "$img@@$((2048 * 512))" ::/EFI/Linux/safespace-arch.efi "$W/st.uki" && cmp -s "$W/st.uki" "$B/boot.efi" || { echo "UKI differs"; return 1; }
		[[ $(od -An -tu2 -j$((2048 * 512 + 11)) -N2 "$img" | tr -d ' ') == 512 ]] || { echo "FAT sector size is not 512"; return 1; }
		for n in root containers; do
			cut_part "$img" "root-$n" "$W/st.root" && cut_part "$img" "root-$n-verity" "$W/st.verity" &&
				veritysetup verify "$W/st.root" "$W/st.verity" "$(cat "$B/roothash-$n")" || { echo "root-$n does not verify"; return 1; }
		done
	}
	check "burn.sh --image from a build" "$CO/burn.sh" combined_20990101-0100 --image "$W/stick1.raw"
	check "... is the build: table, ESP, signed files, every root block by block" stick_ok "$W/stick1.raw"
	check "burn.sh --image from a share directory (SHA256SUMS checked)" "$CO/burn.sh" "$SHARE" --image "$W/stick2.raw"
	SP=$(port)
	serve "$SHARE" "$SP"
	check "burn.sh --image from a server URL (every root streamed)" "$CO/burn.sh" "http://127.0.0.1:$SP/" --image "$W/stick3.raw"
	check "... is the build too" stick_ok "$W/stick3.raw"
	cp "$SHARE/root-containers.img" "$W/root.good"
	printf '\xff' | dd of="$SHARE/root-containers.img" bs=1 seek=4096 conv=notrunc status=none
	refuse "a root image that does not match SHA256SUMS is refused while streaming" "$CO/burn.sh" "http://127.0.0.1:$SP/" --image "$W/stick4.raw"
	check "... and nothing is left behind" test ! -e "$W/stick4.raw"
	cp "$W/root.good" "$SHARE/root-containers.img"
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
	check "uploaded files arrived" bash -c 'cmp -s "$1/rshare/root-root.img" "$2/mkosi.release/root-root.img"' _ "$W" "$CO"
	refuse "rrsync refuses deleting" env RSYNC_RSH="$W/fake-ssh" rsync -r --delete "$W/empty/" "safespace@server:"
	check "... and the release is still there" test -f "$W/rshare/root-root.img"
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
	served=$(tr -d '[:space:]' <"$SHARE/roothash-root")
	mkdir -p "$W/old" && echo 1111111111111111111111111111111111111111111111111111111111111111 >"$W/old/roothash-root"
	cp "$SHARE/root-root.img" "$SHARE/root-root.verity" "$W/old/"
	P1=$(port) P2=$(port)
	serve "$W/old" "$P1"
	serve "$SHARE" "$P2"
	EV=$W/efivars SG=8a3e6c1d-4b2f-4e9a-b7d5-1c0f9e2a6b34
	nr_cmd() { # CMDLINE: run netroot with it (efivars in a directory of the test)
		rm -f "$W/systemctl.calls" "$W/veritysetup.calls"
		mkdir -p "$EV"
		NETROOT_CMDLINE="$1" NETROOT_DIR=$W/nr SAFESPACE_EFIVARS=$EV PATH="$S:$PATH" sh "$NR" >"$W/nr.log" 2>&1
	}
	nr() { # ROOTHASH URL...: netroot against the servers, the hash as combination root
		local h=$1; shift
		nr_cmd "lockdown=integrity safespace.root.root=$h $(printf 'safespace.netroot=%s ' "$@")" || true
	}
	nr "$served" "http://127.0.0.1:$P2/"
	check "the matching release is opened with the signed root hash" grep -q "$served" "$W/veritysetup.calls"
	check "... and no reboot" test ! -e "$W/systemctl.calls"
	: >"$W/http-$P1.log"
	nr "$served" "http://127.0.0.1:$P1/"
	check "only another release served: reboot to load the new boot.efi" grep -qx reboot "$W/systemctl.calls"
	check "... without downloading the root image" bash -c '! grep -q "GET /root-root.img" "$1"' _ "$W/http-$P1.log"
	nr "$served" "http://127.0.0.1:$P1/" "http://127.0.0.1:$P2/"
	check "a stale first server and a matching second one: no reboot" test ! -e "$W/systemctl.calls"
	check "... the second one is used" grep -q "$served" "$W/veritysetup.calls"
	touch "$W/veritysetup.fail"
	nr "$served" "http://127.0.0.1:$P2/"
	check "the right release but a refused image: an error, no reboot loop" test ! -e "$W/systemctl.calls"
	rm -f "$W/veritysetup.fail"
	refuse "a single-root command line (roothash=, no safespace.root.*) opens nothing" nr_cmd "roothash=$served safespace.netroot=http://127.0.0.1:$P2/"
	check "... nothing opened, nothing downloaded" test ! -e "$W/veritysetup.calls"
	# The share's own signed command line, a combination preselected.
	ccmd=$(cat "$SHARE/cmdline") hc=$(cat "$SHARE/roothash-containers")
	printf '\x07\x00\x00\x00containers' >"$EV/SafespaceSelect-$SG"
	: >"$W/http-$P2.log"
	nr_cmd "${ccmd//safespace.netroot=http:\/\/127.0.0.1:$NETPORT\//safespace.netroot=http://127.0.0.1:$P2/}" || true
	check "SafespaceSelect=containers opens that root with its signed hash" grep -q "$hc" "$W/veritysetup.calls"
	check "... downloads only root-containers.img" bash -c 'grep -q "GET /root-containers.img" "$1" && ! grep -q "GET /root-root.img" "$1"' _ "$W/http-$P2.log"
	check "... no reboot" test ! -e "$W/systemctl.calls"
	rm -f "$EV/SafespaceSelect-$SG"
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

# --- compose: the shipped UKI is checked, the initrd's choice of the root ---------------------
if wanted compose && fixtures; then
	section compose
	t_fw() ( # PACKAGES...: builds_check_firmware on a manifest with these packages
		set -Eeuo pipefail
		die() { echo "DIE: $*" >&2; exit 1; }
		HERE=$REPO; source "$REPO/lib/builds.sh"; source "$REPO/tests/lib/fixtures.sh"
		fx_manifest "$W/fw-manifest.json" "$@"
		builds_check_firmware "$W/fw-manifest.json"
	)
	t_fw_refused() { # PACKAGE...: refused, naming exactly the unselected ones (first argument)
		local want=$1; shift
		! t_fw "$@" >"$W/fw.log" 2>&1 && grep -q "outside mkosi.conf's selection were installed: $want (" "$W/fw.log"
	}
	check "builds_finalize: the selected firmware packages pass" t_fw linux=7 linux-firmware-intel=1 linux-firmware-amdgpu=1 linux-firmware-realtek=1 linux-firmware-whence=1
	check "builds_finalize: the linux-firmware meta package fails the build" t_fw_refused linux-firmware linux=7 linux-firmware=1 linux-firmware-intel=1
	check "builds_finalize: linux-firmware-nvidia pulled in fails the build" t_fw_refused linux-firmware-nvidia linux=7 linux-firmware-intel=1 linux-firmware-nvidia=1
	ccmd=$(objcopy -O binary --only-section=.cmdline "$B/boot.efi" /dev/stdout 2>/dev/null | tr -d '\0')
	hr=$(cat "$B/roothash-root") hc=$(cat "$B/roothash-containers")
	check "the UKI names every root in order, without roothash=" \
		bash -c '[[ " $1 " == *" safespace.root.root=$2 safespace.root.containers=$3 "* && " $1 " != *" roothash="* && " $1 " == *" safespace.netroot="* && " $1 " == *" lockdown=integrity "* ]]' _ "$ccmd" "$hr" "$hc"
	check "... signed by the db key, with signed expected PCRs (.pcrsig)" bash -c 'sbverify --cert "$2" "$1" && objdump -h "$1" | grep -q "\.pcrsig"' _ "$B/boot.efi" "$KD/db/db.pem"
	t_initrd() { # COMPOSED FIRST: the first one's initrd, then only the identity key's cpio
		local a b
		a=$(objcopy -O binary --only-section=.initrd "$1" /dev/stdout | wc -c)
		b=$(objcopy -O binary --only-section=.initrd "$2" /dev/stdout | wc -c)
		cmp -s <(objcopy -O binary --only-section=.initrd "$1" /dev/stdout | head -c "$b") <(objcopy -O binary --only-section=.initrd "$2" /dev/stdout) &&
			[[ $(objcopy -O binary --only-section=.initrd "$1" /dev/stdout | tail -c +$((b + 1)) | cpio -t --quiet 2>/dev/null | tr '\n' ' ') == "usr usr/local usr/local/lib usr/local/lib/safespace usr/local/lib/safespace/identity.pem " ]] &&
			((a > b))
	}
	check "... the kernel and initrd of the first combination, plus the identity key" t_initrd "$B/boot.efi" "$CO/parts-20990101-0100/root/boot.efi"
	check "... the identity key in the initrd is the build host's" bash -c 'cmp -s <(objcopy -O binary --only-section=.initrd "$1" /dev/stdout | tail -c 4096 | strings -n 8 | sed -n "/^-----BEGIN PUBLIC KEY/,/^-----END PUBLIC KEY/p") <(openssl x509 -in "$2" -pubkey -noout)' _ "$B/boot.efi" "$KD/identity.crt"
	check "... named \"safespace <version>\" (.osrel), no combination: it serves all" bash -c '
		o=$(objcopy -O binary --only-section=.osrel "$1" /dev/stdout | tr -d "\0")
		grep -qx "PRETTY_NAME=\"safespace 20990101-0100\"" <<<"$o" && ! grep -q "^VARIANT" <<<"$o" && grep -qx "ID=arch" <<<"$o"' _ "$B/boot.efi"
	check "the login banner shows os-release's PRETTY_NAME" grep -qxF '\S{PRETTY_NAME} \r (\l)' "$REPO/mkosi.extra/etc/issue"
	check "safespace-select: the booted combination is the root's own name" grep -q '^booted() { cat /usr/lib/safespace/combination' "$REPO/mkosi.extra/usr/local/sbin/safespace-select"
	# compose_check on a changed copy: what build.sh refuses to call a build.
	t_check() ( # DIR
		set -Eeuo pipefail
		die() { echo "DIE: $*" >&2; exit 1; }
		log() { :; }
		source "$REPO/lib/verify.sh"; source "$REPO/lib/compose.sh"
		COMBO_NAMES=(root containers)
		compose_check "$1" "$KD/db/db.pem"
	)
	check "compose_check passes the build" t_check "$B"
	ctamper() { # NAME REASON COMMAND: change a copy of the build, expect compose_check to refuse for REASON
		rm -rf "$W/ctamper" && cp -a "$B" "$W/ctamper"
		bash -c "$3" _ "$W/ctamper"
		R=$R check "compose_check refuses $1" bash -c '! "$@" >"$W/ct.log" 2>&1 && grep -q -- "$R" "$W/ct.log"' _ t_check "$W/ctamper"
	}
	export -f t_check; export KD W REPO
	cuki="source $REPO/tests/lib/fixtures.sh; fx_uki \$1/boot.efi"
	R="not signed by" ctamper "a UKI signed by another key" - 'sbattach --remove $1/boot.efi >/dev/null; sbsign --key '"$KD"'/KEK/KEK.key --cert '"$KD"'/KEK/KEK.pem --output $1/boot.efi $1/boot.efi >/dev/null 2>&1'
	R="lacks lockdown=integrity" ctamper "a UKI without lockdown=integrity" - "$cuki '${ccmd/ lockdown=integrity/}' $KD/db/db.key $KD/db/db.pem"
	R="still carries roothash=" ctamper "a UKI that still carries roothash=" - "$cuki '$ccmd roothash=$hr' $KD/db/db.key $KD/db/db.pem"
	R="names a combination" ctamper "a UKI named after one combination" - "$cuki '$ccmd' $KD/db/db.key $KD/db/db.pem 'PRETTY_NAME=\"safespace 20990101-0100 root\"'"
	R="no AuthenticAMD microcode" ctamper "a UKI without AMD microcode" - "export FX_UCODE_VENDORS=GenuineIntel; $cuki '$ccmd' $KD/db/db.key $KD/db/db.pem 'PRETTY_NAME=\"safespace 20990101-0100\"'"
	R="no signed expected PCRs" ctamper "a UKI without signed expected PCRs" - "$cuki '$ccmd' $KD/db/db.key $KD/db/db.pem 'PRETTY_NAME=\"safespace 20990101-0100\"'"
	R="not exactly one identity signature, for enter-initrd" ctamper "a UKI without the identity key's signature" - "source $REPO/tests/lib/fixtures.sh; fx_reuki \$1 $KD ''"
	R="not exactly one identity signature, for enter-initrd" ctamper "a UKI whose identity signature covers every phase (a root could unseal)" - "source $REPO/tests/lib/fixtures.sh; fx_reuki \$1 $KD 'enter-initrd enter-initrd:leave-initrd enter-initrd:leave-initrd:sysinit enter-initrd:leave-initrd:sysinit:ready'"
	R="not exactly one identity signature, for enter-initrd" ctamper "a UKI whose identity signature is for leave-initrd" - "source $REPO/tests/lib/fixtures.sh; fx_reuki \$1 $KD 'enter-initrd:leave-initrd'"
	check "compose_check passes a UKI rebuilt with the identity key for enter-initrd" bash -c 'rm -rf "$W/creuki" && cp -a "$1" "$W/creuki" && source "$REPO/tests/lib/fixtures.sh" && fx_reuki "$W/creuki" "$KD" enter-initrd && t_check "$W/creuki" >/dev/null 2>&1' _ "$B"
	R="roothash-containers is not" ctamper "a roothash-<name> that is not the signed one" - 'echo 0000000000000000000000000000000000000000000000000000000000000000 >$1/roothash-containers'
	R="not the combinations" ctamper "combinations in another order" - "$cuki '${ccmd/safespace.root.root=$hr safespace.root.containers=$hc/safespace.root.containers=$hc safespace.root.root=$hr}' $KD/db/db.key $KD/db/db.pem"
	R="systemd-boot.efi is not signed" ctamper "systemd-boot signed by another key" - 'sbattach --remove $1/systemd-boot.efi >/dev/null; sbsign --key '"$KD"'/KEK/KEK.key --cert '"$KD"'/KEK/KEK.pem --output $1/systemd-boot.efi $1/systemd-boot.efi >/dev/null 2>&1'
	R="layout.sfdisk does not match" ctamper "a partition table with another root UUID" - 'sed -i "/name=\"root-containers\"/s/uuid=[0-9A-F-]*/uuid=11111111-2222-3333-4444-555555555555/" $1/layout.sfdisk'

	# The initrd's choice of the root.
	SEL=$REPO/mkosi.initrd.conf/mkosi.extra/usr/local/lib/safespace/select
	SG=8a3e6c1d-4b2f-4e9a-b7d5-1c0f9e2a6b34 EV=$W/sel-efivars
	H1=$(printf '1%.0s' {1..64}) H2=$(printf '2%.0s' {1..64})
	CL="ro safespace.root.root=$H1 safespace.root.containers=$H2"
	# The measuring program, replaced: it records its arguments (PCREXT_FAIL=1: fails).
	PX=$W/pcrextend SR=$W/sel-run
	printf '#!/bin/sh\necho "$*" >>"%s/pcrextend.log"\n[ -z "$PCREXT_FAIL" ]\n' "$W" >"$PX" && chmod +x "$PX"
	t_select() { # CMDLINE ONCE PERSISTENT EXPECTED("name:hash")
		rm -rf "$EV" "$SR" "$W/pcrextend.log" && mkdir -p "$EV"
		[[ -z $2 ]] || printf '\x07\x00\x00\x00%s' "$2" >"$EV/SafespaceSelectOnce-$SG"
		[[ -z $3 ]] || printf '\x07\x00\x00\x00%s' "$3" >"$EV/SafespaceSelect-$SG"
		local got
		got=$(cmdline=$1 SAFESPACE_EFIVARS=$EV SAFESPACE_RUN=$SR SAFESPACE_PCREXTEND=$PX sh -c 'msg() { :; }; . "$0"; select_root || exit 1; echo "$SELECT_NAME:$SELECT_HASH"' "$SEL") || return 1
		[[ $got == "$4" ]] || { echo "got $got"; return 1; }
	}
	check "select: nothing set boots the first combination" t_select "$CL" "" "" "root:$H1"
	check "select: the first is the default, whatever its name" t_select "ro safespace.root.containers=$H2 safespace.root.root=$H1" "" "" "containers:$H2"
	check "select: SafespaceSelect=containers" t_select "$CL" "" containers "containers:$H2"
	check "select: SafespaceSelectOnce wins over SafespaceSelect" t_select "$CL" root containers "root:$H1"
	check "... and is deleted" test ! -e "$EV/SafespaceSelectOnce-$SG"
	check "select: safespace.select= on the command line wins" t_select "$CL safespace.select=containers" root "" "containers:$H2"
	refuse "select: an unknown name stops the boot" t_select "$CL" "" nope ""
	check "select: a variable that is no name is ignored" t_select "$CL" "" 'x;rm' "root:$H1"
	refuse "select: roothash= alone stops the boot (no fallback)" t_select "ro roothash=$H1" "" "" ""
	refuse "select: a variable cannot add a root (no hash of its own)" t_select "$CL" "" "x$H1" ""
	t_select "$CL" "" containers "containers:$H2" >/dev/null
	check "select: the choice is measured into PCR 15 before it is used" bash -c '[[ $(cat "$1") == "--graceful --pcr=15 safespace-combination:containers" ]]' _ "$W/pcrextend.log"
	check "... and recorded in /run/safespace/combination" bash -c '[[ $(cat "$1/combination") == containers ]]' _ "$SR"
	t_twice() { rm -rf "$SR" "$W/pcrextend.log"; cmdline=$CL SAFESPACE_EFIVARS=$EV SAFESPACE_RUN=$SR SAFESPACE_PCREXTEND=$PX sh -c 'msg() { :; }; . "$0"; select_root && select_root' "$SEL" && [[ $(wc -l <"$W/pcrextend.log") == 1 ]]; }
	check "select: measured only once per boot" t_twice
	t_failmeasure() { PCREXT_FAIL=1 t_select "$CL" "" "" "root:$H1"; }
	check "select: a failing measurement does not stop the boot" t_failmeasure
	t_unknown_measured() { t_select "$CL" "" nope ""; test -e "$W/pcrextend.log"; }
	refuse "select: an unknown name is not measured" t_unknown_measured

	# The machine's identity (initrd identity): systemd-creds replaced by a stub.
	# encrypt: header type (signed for tpm2-with-public-key, else plain; STUB_TYPE=plain
	# forces plain) + name + content, base64. decrypt: only with a signature file
	# containing "good" (STUB_NOSIG_OK=1: also with an empty one), and the right name.
	ID=$REPO/mkosi.initrd.conf/mkosi.extra/usr/local/lib/safespace/identity
	CS=$W/creds-stub IR=$W/id-run
	cat >"$CS" <<-'STUB'
		#!/bin/bash
		mode=$1; shift; key="" sig="" name="" files=()
		for a; do case $a in --with-key=*) key=${a#*=} ;; --tpm2-signature=*) sig=${a#*=} ;; --name=*) name=${a#*=} ;; -*) ;; *) files+=("$a") ;; esac; done
		in=${files[0]} out=${files[1]:--}
		if [[ $mode == encrypt ]]; then
			t=5e2d5c7603724eaf843c6fb5f64098f5
			[[ $key == tpm2-with-public-key && -z $STUB_TYPE ]] || t=d4062dfb71ad4c86804b40ef1180f1fc
			{ printf "$(sed 's/../\\x&/g' <<<"$t")"; printf '%s\n' "$name"; cat "$in"; } | base64 -w0 >"$out"
		else
			grep -q good "$sig" 2>/dev/null || { [[ -n $STUB_NOSIG_OK && $(cat "$sig") == '{}' ]]; } || exit 1
			d=$(base64 -d <"$in" | tail -c +17)
			[[ ${d%%$'\n'*} == "$name" ]] || exit 1
			if [[ $out == - ]]; then printf '%s' "${d#*$'\n'}"; else printf '%s' "${d#*$'\n'}" >"$out"; fi
		fi
	STUB
	chmod +x "$CS"
	echo good >"$W/sig-good.json"; echo bad >"$W/sig-bad.json"
	t_id() { # COMBINATION SECUREBOOT SETUPMODE SIGNATURE [ENV...]: run identity, results in $IR/
		rm -rf "$IR" "$W/pcrextend.log" && mkdir -p "$IR/run" "$EV"
		printf '\x06\x00\x00\x00\x0'"$2" >"$EV/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
		printf '\x06\x00\x00\x00\x0'"$3" >"$EV/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c"
		[[ -z $1 ]] || echo "$1" >"$IR/run/combination"
		env "${@:5}" SAFESPACE_EFIVARS=$EV SAFESPACE_RUN=$IR/run SAFESPACE_PCREXTEND=$PX SAFESPACE_CREDS=$CS \
			SAFESPACE_IDENTITY_KEY=/dev/null SAFESPACE_PCRSIG=$4 SAFESPACE_MACHINE_ID=$IR/machine-id \
			sh "$ID" 2>"$IR/log"
	}
	slot() { tail -c +5 "$EV/$1-$SG" 2>/dev/null | sha256sum | cut -c1-16; }
	t_id_first() {
		rm -rf "$EV"; t_id containers 1 0 "$W/sig-good.json" &&
			[[ -e $EV/SafespaceIdMachine-$SG && ! -e $EV/SafespaceIdHostKey-$SG ]] &&
			[[ -s $IR/machine-id && ! -e $IR/run/identity/ssh_host_ed25519_key ]] &&
			cmp -s "$IR/machine-id" "$IR/run/identity/machine-id" &&
			[[ $(cat "$IR/run/identity/released") == SafespaceIdMachine ]] &&
			[[ $(tail -1 "$W/pcrextend.log") == "--graceful --pcr=15 safespace-identity:sealed" ]]
	}
	check "identity: the first sealed boot creates the machine-id slot (no host key: aSSH's), releases it, closes PCR 15" t_id_first
	t_id_sboff() { rm -rf "$EV"; t_id containers 0 0 "$W/sig-good.json"; [[ ! -e $EV/SafespaceIdMachine-$SG && ! -e $IR/machine-id ]] && grep -q 'identity:sealed' "$W/pcrextend.log"; }
	check "identity: no identity with Secure Boot off (and PCR 15 closed)" t_id_sboff
	t_id_setup() { rm -rf "$EV"; t_id containers 1 1 "$W/sig-good.json"; [[ ! -e $EV/SafespaceIdMachine-$SG ]]; }
	check "identity: no identity in Setup Mode" t_id_setup
	t_id_other() {
		rm -rf "$EV"; t_id containers 1 0 "$W/sig-good.json" || return 1
		local h=$(slot SafespaceIdMachine)
		t_id root 1 0 "$W/sig-bad.json"
		[[ ! -e $IR/machine-id && $(slot SafespaceIdMachine) == "$h" ]] && grep -q 'identity:sealed' "$W/pcrextend.log"
	}
	check "identity: another combination: not released, no new identity, PCR 15 closed" t_id_other
	t_id_update() { rm -rf "$EV"; t_id containers 1 0 "$W/sig-good.json" && cp "$IR/machine-id" "$W/mid1" && t_id containers 1 0 "$W/sig-good.json" && cmp -s "$IR/machine-id" "$W/mid1"; }
	check "identity: the assigned combination again: the same machine-id" t_id_update
	t_id_mismatch() {
		rm -rf "$EV"; t_id containers 1 0 "$W/sig-good.json" || return 1
		local h=$(slot SafespaceIdMachine)
		printf '\x07\x00\x00\x00root' >"$EV/SafespaceAssign-$SG"
		t_id containers 1 0 "$W/sig-good.json"
		[[ $(slot SafespaceIdMachine) == "$h" && ! -e $EV/SafespaceAssign-$SG ]] && grep -q "ignoring SafespaceAssign=root" "$IR/log"
	}
	check "identity: SafespaceAssign for another combination than measured: ignored, deleted" t_id_mismatch
	t_id_move() {
		rm -rf "$EV"; t_id containers 1 0 "$W/sig-good.json" || return 1
		local h=$(slot SafespaceIdMachine) m=$(cat "$IR/machine-id")
		printf '\x07\x00\x00\x00containers' >"$EV/SafespaceAssign-$SG"
		t_id containers 1 0 "$W/sig-good.json"
		[[ $(slot SafespaceIdMachine) != "$h" && -s $IR/machine-id && $(cat "$IR/machine-id") != "$m" && ! -e $EV/SafespaceAssign-$SG ]]
	}
	check "identity: SafespaceAssign for the measured combination (safespace-seal --move): a new machine-id" t_id_move
	t_id_plain() { rm -rf "$EV"; t_id containers 1 0 "$W/sig-good.json" STUB_TYPE=plain; [[ ! -e $EV/SafespaceIdMachine-$SG ]] && grep -q "not bound to the signed policy" "$IR/log"; }
	check "identity: a slot without the signed policy type is not written" t_id_plain
	t_id_nosig() { rm -rf "$EV"; t_id containers 1 0 "$W/sig-good.json" STUB_NOSIG_OK=1; [[ ! -e $EV/SafespaceIdMachine-$SG ]] && grep -q "not bound to the signed policy" "$IR/log"; }
	check "identity: a slot that unseals without a signature is not written" t_id_nosig
	t_id_none() { rm -rf "$EV"; t_id "" 1 0 "$W/sig-good.json"; [[ ! -e $EV/SafespaceIdMachine-$SG ]] && grep -q 'identity:sealed' "$W/pcrextend.log"; }
	check "identity: nothing measured: no identity, PCR 15 closed" t_id_none
	t_id_swap() {
		rm -rf "$EV"; t_id containers 1 0 "$W/sig-good.json" || return 1
		echo 0123456789abcdef0123456789abcdef >"$W/other"
		"$CS" encrypt --with-key=tpm2-with-public-key --name=safespace-ssh-host-key "$W/other" "$W/other.cred" &&
			{ printf '\x07\x00\x00\x00'; cat "$W/other.cred"; } >"$EV/SafespaceIdMachine-$SG"
		t_id containers 1 0 "$W/sig-good.json"
		[[ ! -e $IR/machine-id ]]
	}
	check "identity: a credential of another name in the slot is not released" t_id_swap
	check "identity: every sealing uses tpm2-with-public-key" bash -c '! grep -nE "(creds|CREDS\"?) encrypt" "$@" | grep -v "with-key=tpm2-with-public-key"' _ "$ID" "$REPO/mkosi.extra/usr/local/sbin/safespace-seal"
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
# --- aSSH: the machine's host key (lib/assh.sh, the image's assh.conf) ----------------------
if wanted assh && need go; then
	section assh
	AB=$W/assh-bin/assh
	t_assh_build() {
		HERE=$REPO SAFESPACE_GOCACHE=${XDG_CACHE_HOME:-$HOME/.cache}/safespace-tests/go bash -c \
			'die() { echo "$*" >&2; exit 1; }; log() { echo "$*"; }; . "$HERE/lib/assh.sh"; assh_build "$1"' _ "$AB" &&
			go version -m "$AB" | grep -q 'CGO_ENABLED=0' && go version -m "$AB" | grep -q -- '-trimpath=true'
	}
	check "lib/assh.sh builds a static aSSH from the submodule" t_assh_build
	C=$REPO/mkosi.extra/etc/assh/assh.conf
	t_assh_conf() { # assh parses it: the CA file is what is missing, not a line
		local out; out=$("$AB" ca show --config "$C" --ca "$W/no-ca" 2>&1) && return 1
		[[ $out == *no-ca*"no such file"* && $out != *line* ]]
	}
	check "the image's assh.conf is aSSH's (it parses it)" t_assh_conf
	check "assh.conf: the CA in SAFEasshCA, the authority in the TPM" bash -c 'grep -qx "ASSH_CA=efi:SAFEasshCA" "$1" && grep -qx "ASSH_AUTHORITY_TPM=yes" "$1"' _ "$C"
	check "assh.conf: slot 0 = 0,2,7,11,15, slot 1 = 7,15, window 15" bash -c 'grep -qx "ASSH_CA_SLOT_0=0,2,7,11,15" "$1" && grep -qx "ASSH_CA_SLOT_1=7,15" "$1" && grep -qx "ASSH_CA_WINDOW=15" "$1" && [[ $(grep -c "^ASSH_CA_SLOT_" "$1") == 2 ]]' _ "$C"
	A=$REPO/mkosi.extra/usr/lib/systemd/system/assh-agent.service
	check "the agent starts before systemd's PCR 15 units and sysinit (PCR 11 and 15 as the initrd left them)" \
		bash -c 'grep -q "^Before=.*sysinit.target" "$1" && grep -q "^Before=.*systemd-pcrmachine.service" "$1" && grep -q "^Before=.*systemd-pcrfs-root.service" "$1"' _ "$A"
	check "the agent is enabled, sshd includes the host key file it writes; the fallback runs after it, whatever came of it" \
		bash -c 'grep -qx "enable assh-agent.service" "$1" && grep -qx "Include /run/safespace/sshd-hostkey.conf" "$2" && grep -qx "After=assh-agent.service" "$3" && ! grep -q "^Condition" "$3" && grep -q "\[ -s \"\$c\" \] && exit 0" "$3"' _ \
		"$REPO/mkosi.extra/usr/lib/systemd/system-preset/10-safespace.preset" "$REPO/mkosi.extra/etc/ssh/sshd_config.d/10-safespace.conf" "$REPO/mkosi.extra/etc/systemd/system/sshd-hostkeys.service"
	check "the initrd has no ssh (the host key is aSSH's, in the root)" bash -c '! grep -qE "^[[:space:]]+openssh$" <(sed -n "/^InitrdPackages=/,/^[A-Z]/p" "$1")' _ "$REPO/mkosi.conf"
	if need swtpm; then
		check "aSSH's own tests (swtpm)" bash -c 'cd "$1" && GOTOOLCHAIN=local go test -count=1 ./...' _ "$REPO/assh"
	fi
fi

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
