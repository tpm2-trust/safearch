#!/usr/bin/env bash
# Integration test in QEMU, self-contained: builds a test image with a
# throwaway user, releases it into a share of its own, checks it as a
# distribution server does, boots it from a stick and over the network, seals
# it, boots with enforced Secure Boot, and checks every boot over ssh. Runs
# unattended; no LLM, no window, no access to real users, keys or servers.
# Exit 0 only if every step passed.
#
#   tests/vm.sh [--no-build | --build BUILD] [--groups LIST] [STEP...]
#
#   --groups LIST   group set to build and test (default: base)
#   --no-build      test the newest existing test build of that group set
#   --build BUILD   test this existing test build (mkosi.test/vm/builds/)
#   STEP            stick net seal net-sb (default: all)
#
# Kept apart from everything real, in mkosi.test/vm/ (gitignored):
#   id_ed25519, users.conf   the test user "tester" and its key (created once)
#   builds/<build>/          test builds (build.sh --users, --output-root); the
#                            newest per group set is kept. ./build.sh list and
#                            ./release.sh never see them: a test build has the
#                            test key and must never reach a real server.
#   run-<time>/              one run: share/ (the release), logs
# The test build loads its root from http://10.0.2.2:PORT/ (QEMU's view of
# this host); test-vm.sh --netboot serves the share there.
#
# Steps (each boot headless, checked over ssh as tester, then powered off):
#   (always) release.sh into run-<time>/share, then server/safespace-netboot
#           verify on it: the checks a distribution server makes
#   stick   usb-bootdev opened the root, netroot did not run,
#           LoaderDevicePartUUID set, the stick read-only, root verified,
#           system running without failed units
#   net     UEFI HTTP boot of the share: netroot opened the root, no
#           usb-bootdev, no LoaderDevicePartUUID, verified, running
#   seal    Setup Mode -> safespace-seal -> boot with the sealed firmware:
#           Secure Boot enabled (user), verified, running
#   net-sb  network boot with enforced Secure Boot: enabled, verified, running
#
# Prerequisites (all checked before anything starts; the list of what is
# missing, then exit 2):
#   - qemu-desktop, edk2-ovmf, virt-firmware (virt-fw-vars), openssh, curl,
#     binutils, sbsigntools, cryptsetup, dosfstools, mtools, util-linux,
#     python, rsync; /dev/kvm read/write
#   - sudo for ./build.sh (asked once at the start, or a NOPASSWD rule for
#     unattended runs, see README.md "Integration test"); not with --no-build
#   - the public keys of a real build (mkosi.extra/usr/share/safespace/
#     secureboot/db.pem: build.sh writes them on every build)
#   - TCP port 8790 free on 127.0.0.1 (the test's HTTP server)
#   - 4 GiB RAM available, 6 GiB free in mkosi.test/
set -Euo pipefail

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
HERE=$REPO
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; }

BUILD_MODE=build BUILD="" GROUP_LIST=base STEPS=()
while (($#)); do
	case $1 in
		--no-build) BUILD_MODE=existing; shift ;;
		--build) BUILD_MODE=given; BUILD=${2:?--build needs a build}; shift 2 ;;
		--groups) GROUP_LIST=${2:?--groups needs a list}; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		stick | net | seal | net-sb) STEPS+=("$1"); shift ;;
		*) usage >&2; die "unknown argument $1" ;;
	esac
done
((${#STEPS[@]})) || STEPS=(stick net seal net-sb)
wants() { [[ " ${STEPS[*]} " == *" $1 "* ]]; }
cd "$REPO"
# shellcheck source=../lib/groups.sh
source "$REPO/lib/groups.sh"
groups_parse "$GROUP_LIST"
GROUPS_CSV=$(IFS=,; echo "${SAFESPACE_GROUPS[*]}")

VM=mkosi.test/vm                  # relative: build.sh takes paths inside the checkout
PORT_HTTP=8790
URL=http://10.0.2.2:$PORT_HTTP/
DB=$REPO/mkosi.extra/usr/share/safespace/secureboot/db.pem
# shellcheck source=../lib/builds.sh
BUILDS_ROOT=$REPO/$VM/builds source "$REPO/lib/builds.sh"
BUILDS_ROOT=$REPO/$VM/builds

# --- prerequisites ------------------------------------------------------------------------

MISSING=()
miss() { MISSING+=("$*"); }
for c in qemu-system-x86_64:qemu-desktop virt-fw-vars:virt-firmware ssh:openssh ssh-keygen:openssh \
	curl:curl rsync:rsync objcopy:binutils sbverify:sbsigntools veritysetup:cryptsetup mkfs.fat:dosfstools \
	mcopy:mtools sfdisk:util-linux setsid:util-linux python3:python; do
	command -v "${c%%:*}" >/dev/null || miss "${c%%:*} (pacman -S ${c#*:})"
done
for f in OVMF_CODE.4m.fd OVMF_CODE.secboot.4m.fd OVMF_VARS.4m.fd; do
	[[ -f /usr/share/edk2/x64/$f ]] || miss "/usr/share/edk2/x64/$f (pacman -S edk2-ovmf)"
done
[[ -r /dev/kvm && -w /dev/kvm ]] || miss "read/write access to /dev/kvm (group kvm)"
[[ -f $DB ]] || miss "$DB (run a real build once: sudo ./build.sh)"
if [[ $BUILD_MODE == build ]]; then
	if ! sudo -n -l "$REPO/build.sh" >/dev/null 2>&1; then
		if [[ -t 0 ]]; then
			log "sudo for the build (asked once now)"
			sudo -v || miss "sudo for $REPO/build.sh"
		else
			miss "sudo without a password for $REPO/build.sh (unattended run; README.md \"Integration test\")"
		fi
	fi
fi
python3 -I -c 'import socket, sys; s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1])))' "$PORT_HTTP" 2>/dev/null ||
	miss "TCP port $PORT_HTTP on 127.0.0.1 is in use (the test's HTTP server)"
avail=$(awk '/^MemAvailable:/ { print int($2 / 1048576) }' /proc/meminfo)
((avail >= 4)) || miss "4 GiB of available RAM (have $avail GiB)"
mkdir -p "$VM/builds"
free=$(df -BG --output=avail "$VM" | tail -1 | tr -dc 0-9)
((free >= 6)) || miss "6 GiB free disk in mkosi.test/ (have $free GiB)"
if ((${#MISSING[@]})); then
	printf '\e[1;31m==> missing prerequisites:\e[0m\n' >&2
	printf '  - %s\n' "${MISSING[@]}" >&2
	exit 2
fi

# The test user: created once, kept for --no-build.
if [[ ! -f $VM/id_ed25519 || ! -f $VM/users.conf ]]; then
	rm -f "$VM/id_ed25519" "$VM/id_ed25519.pub"
	ssh-keygen -q -t ed25519 -N "" -C "safespace tests/vm.sh" -f "$VM/id_ed25519"
	echo "tester:$(cat "$VM/id_ed25519.pub")" >"$VM/users.conf"
fi
log "prerequisites ok (steps: ${STEPS[*]})"

RUN=$REPO/$VM/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$RUN/share" "$RUN/state"
LOGS=$RUN
RESULTS=()
result() { RESULTS+=("$1 $2${3:+  ($3)}"); printf '  \e[%sm%s\e[0m %s%s\n' "$([[ $1 == PASS ]] && echo 32 || echo 31)" "$1" "$2" "${3:+  ($3)}"; }

# --- build, release, server check ------------------------------------------------------------

case $BUILD_MODE in
	build)
		log "building --groups $GROUPS_CSV (test user, root from $URL)"
		sudo "$REPO/build.sh" --groups "$GROUPS_CSV" --users "$VM/users.conf" --output-root "$VM/builds" --url "$URL" \
			>"$LOGS/build.log" 2>&1 || die "build failed (see ${LOGS#"$REPO"/}/build.log)"
		BUILD=$(builds_newest "$GROUPS_CSV")
		# Only the newest test build per group set stays.
		builds_all | while IFS= read -r b; do
			[[ $b != "$BUILD" && $(builds_groups_of "$b") == "$GROUPS_CSV" ]] && rm -rf -- "${BUILDS_ROOT:?}/$b"
		done ;;
	existing) BUILD=$(builds_newest "$GROUPS_CSV") ;;
	given) BUILD=$(builds_find "$BUILD") ;;
esac
[[ -n $BUILD ]] || die "no test build of $GROUPS_CSV in $VM/builds (run without --no-build)"
DIR=$(builds_dir "$BUILD")
log "build $BUILD"

log "release into ${RUN#"$REPO"/}/share"
"$REPO/release.sh" --builds "$BUILDS_ROOT" --build "$BUILD" --stage "$RUN/stage" --push "$RUN/share" \
	>"$LOGS/release.log" 2>&1 && result PASS release || { result FAIL release "see ${LOGS#"$REPO"/}/release.log"; }
printf 'SHARE=%s\nSTATE=%s\nDB_CERT=%s\nSERVER_URL=http://10.0.2.2:%s\nDHCP_MODE=off\n' \
	"$RUN/share" "$RUN/state" "$DB" "$PORT_HTTP" >"$RUN/server.conf"
chmod 0644 "$RUN/server.conf"
SAFESPACE_SERVER_CONF=$RUN/server.conf "$REPO/server/safespace-netboot" verify >"$LOGS/server-verify.log" 2>&1 &&
	result PASS server-verify || result FAIL server-verify "see ${LOGS#"$REPO"/}/server-verify.log"

# --- booting -------------------------------------------------------------------------------

SSH=(ssh -i "$REPO/$VM/id_ed25519" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=error -o ConnectTimeout=5)
VM_PID="" PORT=""
free_port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
vm_ssh() { "${SSH[@]}" -p "$PORT" tester@127.0.0.1 "$@"; }
vm_kill() {
	[[ -n $VM_PID ]] || return 0
	kill -- "-$VM_PID" 2>/dev/null
	for _ in $(seq 20); do kill -0 "$VM_PID" 2>/dev/null || break; sleep 1; done
	kill -9 -- "-$VM_PID" 2>/dev/null
	VM_PID=""
}
trap vm_kill EXIT

# vm_start NAME TEST-VM-ARGS...: boot, wait for ssh and a finished start-up.
# Runs in this shell (never in $(...): VM_PID and PORT must reach vm_stop);
# on failure the reason is in ERR.
ERR=""
vm_start() {
	local name=$1; shift
	ERR=""
	PORT=$(free_port)
	QEMU_EXTRA='-display none' setsid "$REPO/test-vm.sh" "$@" --ssh "$PORT" >"$LOGS/$name.log" 2>&1 &
	VM_PID=$!
	for _ in $(seq 150); do
		vm_ssh true 2>/dev/null && break
		kill -0 "$VM_PID" 2>/dev/null || { ERR="QEMU exited (see ${LOGS#"$REPO"/}/$name.log)"; return 1; }
		sleep 2
	done
	vm_ssh true 2>/dev/null || { ERR="no ssh after 300 s"; return 1; }
	vm_ssh 'systemctl is-system-running --wait >/dev/null 2>&1; true'
}

vm_stop() { # NAME: power off, then make sure QEMU is gone
	vm_ssh 'sudo systemctl poweroff' >/dev/null 2>&1 || true
	for _ in $(seq 60); do kill -0 "$VM_PID" 2>/dev/null || break; sleep 1; done
	cp -f "$REPO/mkosi.test/serial.log" "$LOGS/$1.serial.log" 2>/dev/null || true
	vm_kill
}

# What a boot looks like from inside, as KEY=VALUE lines.
PROBE='
v=/sys/firmware/efi/efivars/LoaderDevicePartUUID-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
[ -e $v ] && echo path_var=set || echo path_var=unset
echo usb_bootdev=$(sudo dmesg | grep -c "usb-bootdev: root opened")
echo netroot=$(sudo dmesg | grep -c "netroot: root opened")
echo root=$(findmnt -no SOURCE,FSTYPE / | tr -s " " ,)
echo verity=$(sudo veritysetup status root | sed -n "s/^ *status: *//p")
data=$(sudo veritysetup status root | sed -n "s/^ *data device: *//p")
disk=$(lsblk -no PKNAME "$data" 2>/dev/null | head -1)
if [ -n "$disk" ]; then
	ro=1; for d in /dev/$disk /dev/$disk?*; do [ "$(sudo blockdev --getro $d)" = 1 ] || ro=0; done
	echo stick_ro=$ro
fi
echo state=$(systemctl is-system-running)
echo failed=$(systemctl --failed --no-legend --plain | wc -l)
echo secure_boot=$(bootctl status 2>/dev/null | sed -n "s/^ *Secure Boot: *//p" | head -1 | tr " " _)
'
probe() { vm_ssh "$PROBE" >"$LOGS/$1.probe" 2>&1; }
val() { sed -n "s/^$2=//p" "$LOGS/$1.probe" | head -1; }

# expect NAME KEY=VALUE...: every key has the value (VALUE* = starts with)
expect() {
	local name=$1 kv k v got bad=""; shift
	for kv in "$@"; do
		k=${kv%%=*} v=${kv#*=} got=$(val "$name" "$k")
		if [[ $v == *'*' ]]; then [[ $got == "${v%\*}"* ]] || bad+="$k=$got (want $v) "
		else [[ $got == "$v" ]] || bad+="$k=$got (want $v) "; fi
	done
	if [[ -z $bad ]]; then result PASS "$name"; else result FAIL "$name" "$bad"; fi
}

COMMON=(root=/dev/mapper/root,erofs verity=verified state=running failed=0)
STICK=$RUN/stick.raw

if wants stick || wants seal; then
	log "assembling the stick image"
	(source "$REPO/lib/stick.sh"; stick_write "$STICK" "$RUN/share") >"$LOGS/stick-image.log" 2>&1 ||
		die "could not assemble the stick image (see ${LOGS#"$REPO"/}/stick-image.log)"
fi

if wants stick; then
	log "step stick: boot from a USB stick"
	if vm_start stick "$STICK"; then
		probe stick
		expect stick path_var=set usb_bootdev=1 netroot=0 stick_ro=1 "${COMMON[@]}"
	else
		result FAIL stick "$ERR"
	fi
	vm_stop stick
fi

if wants net; then
	log "step net: UEFI HTTP boot of the share"
	if vm_start net --netboot --tree "$RUN/share"; then
		probe net
		expect net path_var=unset usb_bootdev=0 netroot=1 "${COMMON[@]}"
	else
		result FAIL net "$ERR"
	fi
	vm_stop net
fi

if wants seal; then
	log "step seal: Setup Mode, safespace-seal, boot sealed"
	if vm_start seal-setup "$STICK" --setup-mode; then
		probe seal-setup
		vm_ssh 'echo YES | sudo safespace-seal' >"$LOGS/seal.log" 2>&1
		if [[ $(val seal-setup secure_boot) == *setup* ]] && grep -q "Sealed." "$LOGS/seal.log"; then
			vm_stop seal-setup
			if vm_start seal "$STICK" --sealed; then
				probe seal
				expect seal secure_boot=enabled* path_var=set usb_bootdev=1 "${COMMON[@]}"
			else
				result FAIL seal "$ERR"
			fi
			vm_stop seal
		else
			result FAIL seal "not in Setup Mode or safespace-seal failed (see ${LOGS#"$REPO"/}/seal.log)"
			vm_stop seal-setup
		fi
	else
		result FAIL seal "$ERR"
		vm_stop seal-setup
	fi
fi

if wants net-sb; then
	log "step net-sb: UEFI HTTP boot with enforced Secure Boot"
	if vm_start net-sb --netboot --tree "$RUN/share" --secure-boot; then
		probe net-sb
		expect net-sb secure_boot=enabled* path_var=unset netroot=1 "${COMMON[@]}"
	else
		result FAIL net-sb "$ERR"
	fi
	vm_stop net-sb
fi

# --- report --------------------------------------------------------------------------------

# The stick image is large and can be assembled again; the logs stay.
rm -f "$STICK"
printf '\n\e[1mbuild %s\e[0m\n' "$BUILD"
printf '  %s\n' "${RESULTS[@]}"
printf 'logs: %s\n' "${RUN#"$REPO"/}"
for r in "${RESULTS[@]}"; do [[ $r == PASS* ]] || exit 1; done
exit 0
