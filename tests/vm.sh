#!/usr/bin/env bash
# Integration test in QEMU, self-contained: builds a test image with a
# throwaway user, releases it into a share of its own, checks it as a
# distribution server does, boots it from a stick and over the network, seals
# it, boots with enforced Secure Boot, and checks every boot over ssh. Runs
# unattended; no LLM, no window, no access to real users, keys or servers.
# Exit 0 only if every step passed.
#
#   tests/vm.sh [--no-build | --build BUILD] [STEP...]
#
#   (default)       build and test the whole stack: every combination of
#                   combinations.conf, as build.sh builds it
#   --no-build      test the newest existing test build
#   --build BUILD   test this existing test build (mkosi.test/vm/builds/)
#   STEP            stick net seal net-sb select (default: all; select needs
#                   seal and runs it first)
#
# Kept apart from everything real, in mkosi.test/vm/ (gitignored):
#   id_ed25519, users.conf   the test user "tester" and its key: created here
#                            once, used for nothing else (build.sh --users)
#   builds/<build>/          test builds (build.sh --users, --output-root); the
#                            newest is kept. ./build.sh list and
#                            ./release.sh never see them: a test build has the
#                            test key and must never reach a real server.
#   run-<time>/              one run: share/ (the release), logs
# The test build loads its root from http://10.0.2.2:PORT/ (QEMU's view of
# this host); test-vm.sh --netboot serves the share there.
#
# Steps (each boot headless, checked over ssh as tester, then powered off):
#   (always) release.sh into run-<time>/share, then server/safespace-netboot
#           verify on it: the checks a distribution server makes
#   (every boot) root verified, kernel lockdown "integrity", running, no
#           failed units
#   stick   usb-bootdev opened the root, netroot did not run,
#           LoaderDevicePartUUID set, the stick read-only, root verified,
#           system running without failed units
#   net     UEFI HTTP boot of the share: netroot opened the root, no
#           usb-bootdev, no LoaderDevicePartUUID, verified, running
#   seal    Setup Mode -> safespace-seal -> boot with the sealed firmware:
#           Secure Boot enabled (user), verified, running
#   net-sb  network boot with enforced Secure Boot: enabled, verified, running
#   select  on the sealed firmware of seal, every combination of the build
#           booted once, each checked for its name and its package groups
#           (/usr/lib/safespace/groups, the docker command exactly with the
#           docker group): the first without a selection; safespace-select
#           set SECOND -> SECOND; once FIRST -> FIRST for one boot; SECOND
#           again (persistent); then once for each further combination; clear.
#           A combination that is the first plus the group debug must have the
#           first one's setuid/setgid files, file capabilities and enabled
#           units (debug adds packages, nothing else). Every boot with Secure
#           Boot enabled and verified.
#
# Prerequisites (all checked before anything starts; the list of what is
# missing, then exit 2):
#   - qemu-desktop, edk2-ovmf, virt-firmware (virt-fw-vars), openssh, curl,
#     binutils, sbsigntools, cryptsetup, dosfstools, mtools, util-linux,
#     python, rsync; /dev/kvm read/write
#   - sudo for ./build.sh (asked once at the start, or a NOPASSWD rule for
#     unattended runs, see README.md "Integration test"); not with --no-build
#   - with --no-build / --build: the public keys the test build was signed
#     with (mkosi.extra/usr/share/safespace/secureboot/db.pem: every build,
#     the test build too, exports them)
#   - TCP port 8790 free on 127.0.0.1 (the test's HTTP server)
#   - 4 GiB RAM available, 6 GiB + 4 GiB per combination free in mkosi.test/
set -Euo pipefail

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
HERE=$REPO
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; }

BUILD_MODE=build BUILD="" STEPS=()
while (($#)); do
	case $1 in
		--no-build) BUILD_MODE=existing; shift ;;
		--build) BUILD_MODE=given; BUILD=${2:?--build needs a build}; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		stick | net | seal | net-sb | select) STEPS+=("$1"); shift ;;
		*) usage >&2; die "unknown argument $1" ;;
	esac
done
((${#STEPS[@]})) || STEPS=(stick net seal net-sb select)
wants() { [[ " ${STEPS[*]} " == *" $1 "* ]]; }
# select boots the firmware seal sealed
wants select && ! wants seal && STEPS=(seal "${STEPS[@]}")
cd "$REPO"

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
# A test build exports the keys it is signed with; an existing one needs them.
[[ $BUILD_MODE == build || -f $DB ]] || miss "$DB (the keys the test build was signed with: run without --no-build)"
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
need_disk=$((6 + 4 * $(grep -c '^[a-z]' combinations.conf)))
((free >= need_disk)) || miss "$need_disk GiB free disk in mkosi.test/ (have $free GiB)"
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
		log "building the whole stack (test user, root from $URL)"
		sudo "$REPO/build.sh" --users "$VM/users.conf" --output-root "$VM/builds" --url "$URL" \
			>"$LOGS/build.log" 2>&1 || die "build failed (see ${LOGS#"$REPO"/}/build.log)"
		BUILD=$(builds_newest)
		# Only the newest test build stays.
		builds_all | while IFS= read -r b; do
			[[ $b == "$BUILD" ]] || rm -rf -- "${BUILDS_ROOT:?}/$b"
		done ;;
	existing) BUILD=$(builds_newest) ;;
	given) BUILD=$(builds_find "$BUILD") ;;
esac
[[ -n $BUILD ]] || die "no test build in $VM/builds (run without --no-build)"
DIR=$(builds_dir "$BUILD")
# The combinations of the build ("name:group+group"), the first is the default.
mapfile -t COMBOS < <(builds_info "$DIR" combinations | tr ',' '\n')
((${#COMBOS[@]})) || die "$BUILD names no combinations"
log "build $BUILD: ${COMBOS[*]}"

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
echo combination=$(sudo dmesg | sed -n "s/.*\(usb-bootdev\|netroot\): combination \([a-z0-9-]*\) .*/\2/p" | tail -1)
command -v docker >/dev/null && echo docker=yes || echo docker=no
echo groups=$(cat /usr/lib/safespace/groups)
# What a package can add to the attack surface besides its files: setuid/setgid
# programs, file capabilities, enabled units (system and user), as short hashes.
echo suid=$(sudo find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | sort | sha256sum | cut -c1-16)
echo caps=$(sudo getcap -r /usr 2>/dev/null | sort | sha256sum | cut -c1-16)
echo enabled=$( (systemctl list-unit-files --state=enabled --no-legend; systemctl --global list-unit-files --state=enabled --no-legend) 2>/dev/null | awk "{ print \$1 }" | sort | sha256sum | cut -c1-16)
echo lockdown=$(sudo cat /sys/kernel/security/lockdown | sed -n "s/.*\[\(.*\)\].*/\1/p")
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

COMMON=(root=/dev/mapper/root,erofs verity=verified state=running failed=0 lockdown=integrity)
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

if wants select; then
	log "step select: every combination on the sealed firmware"
	SEALED=(secure_boot=enabled* path_var=set usb_bootdev=1 "${COMMON[@]}")
	# What a combination must look like from inside: its name, its groups,
	# the docker command exactly with the docker group.
	looks() { # "name:group+group"
		local n=${1%%:*} g=${1#*:} d=no
		[[ +$g+ == *+docker+* ]] && d=yes
		echo "combination=$n" "groups=${g//+/,}" "docker=$d"
	}
	# sel_boot NAME COMBO COMMAND-AFTER: boot sealed, check, run a command, power off
	sel_boot() {
		local name=$1 combo=$2 cmd=$3 want k
		read -ra want <<<"$(looks "$combo")"
		if [[ ${combo#*:} == "${COMBOS[0]#*:}+debug" ]]; then
			for k in suid caps enabled; do want+=("$k=$(val select-default "$k")"); done
		fi
		if vm_start "$name" "$STICK" --sealed; then
			probe "$name"
			expect "$name" "${want[@]}" "${SEALED[@]}"
			vm_ssh "$cmd" >>"$LOGS/select.log" 2>&1 || result FAIL "$name" "'$cmd' failed (see ${LOGS#"$REPO"/}/select.log)"
		else
			result FAIL "$name" "$ERR"
		fi
		vm_stop "$name"
	}
	if [[ ! -f $REPO/mkosi.test/sealed-vars.fd ]]; then
		result FAIL select "no sealed firmware variables (the step seal failed?)"
	elif ((${#COMBOS[@]} < 2)); then
		sel_boot select-default "${COMBOS[0]}" 'sudo safespace-select list'
	else
		first=${COMBOS[0]%%:*} second=${COMBOS[1]%%:*}
		sel_boot select-default "${COMBOS[0]}" "sudo safespace-select list && sudo safespace-select set $second"
		sel_boot "select-$second" "${COMBOS[1]}" "sudo safespace-select list && sudo safespace-select once $first"
		sel_boot select-once "${COMBOS[0]}" 'sudo safespace-select list'
		# Every further combination once, from the boot before it; the last clears.
		next=clear
		((${#COMBOS[@]} > 2)) && next="once ${COMBOS[2]%%:*}"
		sel_boot select-persistent "${COMBOS[1]}" "sudo safespace-select $next"
		for ((i = 2; i < ${#COMBOS[@]}; i++)); do
			next=clear
			((i + 1 < ${#COMBOS[@]})) && next="once ${COMBOS[i + 1]%%:*}"
			sel_boot "select-${COMBOS[i]%%:*}" "${COMBOS[i]}" "sudo safespace-select list && sudo safespace-select $next"
		done
	fi
fi

# --- report --------------------------------------------------------------------------------

# The stick image is large and can be assembled again; the logs stay.
rm -f "$STICK"
printf '\n\e[1mbuild %s\e[0m\n' "$BUILD"
printf '  %s\n' "${RESULTS[@]}"
printf 'logs: %s\n' "${RUN#"$REPO"/}"
for r in "${RESULTS[@]}"; do [[ $r == PASS* ]] || exit 1; done
exit 0
