#!/usr/bin/env bash
# Integration test in QEMU, self-contained: builds a test image with a
# throwaway user, releases it into a share of its own, checks it as a
# distribution server does, boots it from a stick and over the network, seals
# it, boots with enforced Secure Boot, and checks every boot over ssh. Runs
# unattended; no LLM, no window, no access to real users, keys or servers.
# Exit 0 only if every step passed.
#
#   tests/vm.sh [--no-build | --build BUILD] [--jobs N] [STEP...]
#
#   (default)       build and test the whole stack: every combination of
#                   combinations.conf, as build.sh builds it
#   --no-build      test the newest existing test build
#   --build BUILD   test this existing test build (mkosi.test/vm/builds/)
#   --jobs N        at most N VMs at a time (default: what the free RAM allows
#                   for network boots of the largest root, at most 4)
#   STEP            stick net seal net-sb select identity (default: all;
#                   select and identity need seal and run it first)
#
# Kept apart from everything real, in mkosi.test/vm/ (gitignored):
#   id_ed25519, users.conf   the test user "tester" and its key: created here
#                            once, used for nothing else (build.sh --users)
# The test build's combinations: tests/vm.combinations.conf (build.sh
# --combinations), few to keep the test fast: root (base), containers (base,docker).
#   builds/<build>/          test builds (build.sh --users, --output-root); the
#                            newest is kept. ./build.sh list and
#                            ./release.sh never see them: a test build has the
#                            test key and must never reach a real server.
#   run-<time>/              one run: share/ (the release), logs, w/<step>/
#                            (the step's VM files: test-vm.sh --work)
# The test build loads its root from http://10.0.2.2:PORT/ (QEMU's view of
# this host); one HTTP server serves the share there for every network boot.
# The steps run side by side (--jobs); select waits for seal.
#
# Steps (each boot headless, checked over ssh as tester, then powered off):
#   (always) release.sh into run-<time>/share, then server/safespace-netboot
#           verify on it: the checks a distribution server makes; the UKI's
#           initrd carries the Realtek NIC firmware (initrd-firmware)
#   (every boot) root verified, kernel lockdown "integrity", running, no
#           failed units
#   stick   usb-bootdev opened the root, netroot did not run,
#           LoaderDevicePartUUID set, the stick read-only, root verified,
#           system running without failed units; without a TPM (the
#           throwaway host key; stick and seal are the boots without one,
#           every other step boots with a TPM, as the machines do)
#   net     UEFI HTTP boot of the share: netroot opened the root, no
#           usb-bootdev, no LoaderDevicePartUUID, verified, running
#   seal    Setup Mode -> safespace seal -> boot with the sealed firmware:
#           Secure Boot enabled (user), verified, running
#   net-sb  network boot with enforced Secure Boot: enabled, verified, running
#   select  on the sealed firmware of seal, every combination of the build
#           booted, each checked for its name (also os-release PRETTY_NAME
#           "safespace <version> <name>" and the login banner) and its package groups
#           (/usr/lib/safespace/groups, the docker command exactly with the
#           docker group). One VM, one boot after the other, safespace select:
#           no selection -> FIRST; set SECOND -> SECOND; once FIRST -> FIRST for
#           one boot; SECOND again (persistent); clear -> FIRST. Side by side,
#           every further combination in a VM of its own, its
#           SafespaceSelectOnce written into a copy of the sealed variables
#           (virt-fw-vars): that root opened, the variable deleted.
#           A combination that is the first plus the group debug must have the
#           first one's setuid/setgid files, file capabilities and enabled
#           units (debug adds packages, nothing else). Every boot with Secure
#           Boot enabled and verified.
#   identity the machine identity (aSSH's CA in the TPM, the machine-id), on a
#           TPM of its own (swtpm) and a copy of the sealed firmware: the first
#           two boots one after the other, then every further case side by side
#           on a copy of their TPM and variables; a client that trusts only the CA's @cert-authority
#           line (StrictHostKeyChecking yes): the first sealed boot creates the
#           machine-id; aSSH's temporary key, the state recorded;
#           safespace identity create (PIN, lockout authorization) in that
#           boot, still no certificate; the next boot certified through slot 0,
#           the client logs in, an agent restart gets no certificate (window
#           closed), its root cannot unseal the machine-id (also not after
#           extending PCR 15); another combination once: temporary key,
#           nothing released, identity approve refused; network boot: certified; an
#           option ROM more (PCR 2): slot 1, identity approve, slot 0; another db
#           certificate (PCR 7): temporary, identity move keeps it there (a new
#           machine-id); safespace select NAME from the certified default: a
#           wrong PIN selects nothing, the PIN moves the identity without
#           booting NAME first: NAME's next boot certified with the same
#           machine-id, wrong PINs lock out; the default afterwards: temporary
#           (its approvals revoked); identity clear, identity create: the
#           next boot certified by the new CA, the old line refused; SAFEasshCA
#           damaged, so the agent fails: sshd up with a throwaway key, the
#           console says why. Beside them a new TPM with the SHA-1 bank only
#           (as the T450s's firmware leaves it): without safespace tpm sha1
#           on no machine-id and the temporary key; with it the machine-id,
#           identity create, the next boot certified; tpm sha1 off: neither.
#
# Prerequisites (all checked before anything starts; the list of what is
# missing, then exit 2):
#   - qemu-desktop, edk2-ovmf, virt-firmware (virt-fw-vars), openssh, curl,
#     binutils, sbsigntools, cryptsetup, dosfstools, mtools, util-linux,
#     python, rsync; /dev/kvm read/write; swtpm, swtpm_setup (step identity)
#   - sudo for ./build.sh (asked once at the start, or a NOPASSWD rule for
#     unattended runs, see README.md "Integration test"); not with --no-build
#   - with --no-build / --build: the public keys the test build was signed
#     with (mkosi.extra/usr/share/safespace/secureboot/db.pem: every build,
#     the test build too, exports them)
#   - TCP port 8790 free on 127.0.0.1 (the test's HTTP server)
#   - 4 GiB RAM available (more boots side by side with more), 6 GiB + 4 GiB
#     per combination free in mkosi.test/
set -Euo pipefail

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
HERE=$REPO
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; }

BUILD_MODE=build BUILD="" STEPS=() JOBS=""
while (($#)); do
	case $1 in
		--no-build) BUILD_MODE=existing; shift ;;
		--build) BUILD_MODE=given; BUILD=${2:?--build needs a build}; shift 2 ;;
		--jobs) JOBS=${2:?--jobs needs a number}; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		stick | net | seal | net-sb | select | identity) STEPS+=("$1"); shift ;;
		*) usage >&2; die "unknown argument $1" ;;
	esac
done
[[ -z $JOBS || $JOBS =~ ^[1-9]$ ]] || die "--jobs needs a number from 1 to 9, got '$JOBS'"
((${#STEPS[@]})) || STEPS=(stick net seal net-sb select identity)
wants() { [[ " ${STEPS[*]} " == *" $1 "* ]]; }
# select and identity boot the firmware seal sealed
{ wants select || wants identity; } && ! wants seal && STEPS=(seal "${STEPS[@]}")
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
wants identity && ! { command -v swtpm && command -v swtpm_setup; } >/dev/null && miss "swtpm (pacman -S swtpm; the step identity's TPM)"
# A build builds aSSH (lib/assh.sh) with the build host's Go.
[[ $BUILD_MODE != build ]] || command -v go >/dev/null || miss "go (pacman -S go; build.sh builds aSSH)"
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
COMBOS_FILE=tests/vm.combinations.conf
need_disk=$((6 + 4 * $(grep -c '^[a-z]' "$COMBOS_FILE")))
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
mkdir -p "$RUN/share" "$RUN/state" "$RUN/results"
LOGS=$RUN
# result PASS|FAIL NAME [REASON]: shown at once, kept in results/$KEY for the report
KEY=00
result() {
	printf '%s %s%s\n' "$1" "$2" "${3:+  ($3)}" >>"$RUN/results/$KEY"
	printf '  \e[%sm%s\e[0m %s%s\n' "$([[ $1 == PASS ]] && echo 32 || echo 31)" "$1" "$2" "${3:+  ($3)}"
}

# --- build, release, server check ------------------------------------------------------------

case $BUILD_MODE in
	build)
		log "building the whole stack (test user, root from $URL)"
		sudo "$REPO/build.sh" --users "$VM/users.conf" --combinations "$COMBOS_FILE" --output-root "$VM/builds" --url "$URL" \
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
VERSION=$(builds_version_of "$BUILD")

log "release into ${RUN#"$REPO"/}/share"
KEY=01-release
"$REPO/release.sh" --builds "$BUILDS_ROOT" --build "$BUILD" --stage "$RUN/stage" --push "$RUN/share" \
	>"$LOGS/release.log" 2>&1 && result PASS release || { result FAIL release "see ${LOGS#"$REPO"/}/release.log"; }
printf 'SHARE=%s\nSTATE=%s\nDB_CERT=%s\nSERVER_URL=http://10.0.2.2:%s\nDHCP_MODE=off\n' \
	"$RUN/share" "$RUN/state" "$DB" "$PORT_HTTP" >"$RUN/server.conf"
chmod 0644 "$RUN/server.conf"
KEY=02-server-verify
SAFESPACE_SERVER_CONF=$RUN/server.conf "$REPO/server/safespace-netboot" verify >"$LOGS/server-verify.log" 2>&1 &&
	result PASS server-verify || result FAIL server-verify "see ${LOGS#"$REPO"/}/server-verify.log"
# The network boot needs the NIC before the root: the initrd's module archive
# (uncompressed cpio, firmware from the root) must carry the Realtek NIC firmware.
KEY=03-initrd-firmware
n=$(objcopy -O binary --only-section=.initrd "$DIR/boot.efi" /dev/stdout 2>/dev/null | grep -ac 'usr/lib/firmware/rtl_nic/rtl8168') || n=0
if ((n)); then result PASS initrd-firmware; else result FAIL initrd-firmware "no rtl_nic/ firmware in the UKI's initrd"; fi

# --- booting -------------------------------------------------------------------------------
# The boots run side by side, at most $JOBS VMs at a time. Each step has its own work
# directory for its VMs (firmware variables, serial log, qga socket: test-vm.sh --work), its
# own ssh port and log files; one HTTP server serves the share to every network boot (its
# port is in the signed URL). Each step writes its results to results/<key>; the report
# lists them in key order, whatever order the steps finished in.

SSH=(ssh -i "$REPO/$VM/id_ed25519" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=error -o ConnectTimeout=5)
SELECT_GUID=8a3e6c1d-4b2f-4e9a-b7d5-1c0f9e2a6b34
VM_PID="" PORT="" WORK=""
free_port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
vm_ssh() { "${SSH[@]}" -p "$PORT" tester@127.0.0.1 "$@"; }
vm_kill() {
	[[ -n $VM_PID ]] || return 0
	kill -- "-$VM_PID" 2>/dev/null
	for _ in $(seq 20); do kill -0 "$VM_PID" 2>/dev/null || break; sleep 1; done
	kill -9 -- "-$VM_PID" 2>/dev/null
	VM_PID=""
}
# On any exit of the test: every step, every VM (by process group), the HTTP server.
HTTP_PID=""
: >"$RUN/vm.pids"
cleanup() {
	local p
	jobs -p | xargs -r kill 2>/dev/null
	while read -r p; do kill -9 -- "-$p" 2>/dev/null; done <"$RUN/vm.pids"
	[[ -z $HTTP_PID ]] || kill "$HTTP_PID" 2>/dev/null
}
trap cleanup EXIT

# vm_start NAME TEST-VM-ARGS...: boot, wait for ssh and a finished start-up.
# Runs in the step's shell (never in $(...): VM_PID and PORT must reach vm_stop);
# on failure the reason is in ERR.
ERR=""
vm_start() {
	local name=$1; shift
	ERR=""
	PORT=$(free_port)
	QEMU_EXTRA="-display none ${VM_QEMU_EXTRA:-}" setsid "$REPO/test-vm.sh" "$@" --work "$WORK" --ssh "$PORT" >"$LOGS/$name.log" 2>&1 &
	VM_PID=$!
	echo "$VM_PID" >>"$RUN/vm.pids"
	for _ in $(seq $((${VM_WAIT:-300} / 2))); do
		vm_ssh true 2>/dev/null && break
		kill -0 "$VM_PID" 2>/dev/null || { ERR="QEMU exited (see ${LOGS#"$REPO"/}/$name.log)"; return 1; }
		sleep 2
	done
	vm_ssh true 2>/dev/null || { ERR="no ssh after ${VM_WAIT:-300} s"; return 1; }
	vm_ssh 'systemctl is-system-running --wait >/dev/null 2>&1; true'
}

vm_stop() { # NAME: power off, then make sure QEMU is gone
	vm_ssh 'sudo systemctl poweroff' >/dev/null 2>&1 || true
	for _ in $(seq 60); do kill -0 "$VM_PID" 2>/dev/null || break; sleep 1; done
	cp -f "$WORK/serial.log" "$LOGS/$1.serial.log" 2>/dev/null || true
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
# The name the system shows (spaces as _): os-release, the console login banner.
echo named=$(cat /usr/lib/safespace/combination)
echo pretty=$(. /etc/os-release; echo "$PRETTY_NAME" | tr " " _)
echo issue=$(script -qc "agetty --show-issue" /dev/null | head -1 | tr -d "\r" | tr " " _)
# What a package can add to the attack surface besides its files: setuid/setgid
# programs, file capabilities, enabled units (system and user), as short hashes.
echo suid=$(sudo find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | sort | sha256sum | cut -c1-16)
echo caps=$(sudo getcap -r /usr 2>/dev/null | sort | sha256sum | cut -c1-16)
echo enabled=$( (systemctl list-unit-files --state=enabled --no-legend; systemctl --global list-unit-files --state=enabled --no-legend) 2>/dev/null | awk "{ print \$1 }" | sort | sha256sum | cut -c1-16)
# Smaller roots (mkosi.conf KernelModules=/FirmwareFiles=/RemoveFiles=, mkosi.postinst):
# what must not be in any root, by name, or "ok".
bad=""
for p in /usr/lib/firmware/nvidia /usr/lib/firmware/intel/iwlwifi /usr/share/man /usr/share/doc /usr/include; do [ -e $p ] && bad="$bad,$p"; done
find /usr/lib/modules -name "*.ko*" \( -name "cfg80211.*" -o -name "mac80211.*" -o -name "bluetooth.*" -o -name "nouveau.*" -o -path "*/drivers/net/wireless/*" \) | grep -q . && bad="$bad,modules"
modprobe -n -q iwlwifi 2>/dev/null && bad="$bad,modules.dep"
ls /usr/share/locale | grep -qvx -e en -e en_US -e locale.alias && bad="$bad,locale"
# Firmware by package (mkosi.conf): nothing but the selected ones installed.
fw=$(pacman -Qq | grep -E "^linux-firmware(-|\$)" | grep -vxE "linux-firmware-(intel|amdgpu|realtek|whence)" | tr "\n" ,)
[ -n "$fw" ] && bad="$bad,packages:$fw"
for p in amd-ucode intel-ucode linux-firmware-realtek; do pacman -Qq $p >/dev/null 2>&1 || bad="$bad,missing:$p"; done
echo slim=${bad:-ok}
echo lockdown=$(sudo cat /sys/kernel/security/lockdown | sed -n "s/.*\[\(.*\)\].*/\1/p")
echo secure_boot=$(bootctl status 2>/dev/null | sed -n "s/^ *Secure Boot: *//p" | head -1 | tr " " _)
# The machine identity (step identity): the host key sshd serves (aSSH'"'"'s, or a
# throwaway one without a TPM), whether the CA certified it and through which slot,
# the machine-id, the slots the initrd released ("released" list), whether it
# created one this boot.
hk=$(sed -n "s/^HostKey //p" /run/safespace/sshd-hostkey.conf 2>/dev/null | head -1)
echo hostkey=$(sudo ssh-keygen -lf "$hk" 2>/dev/null | cut -d" " -f2)
case $hk in /run/assh/*) echo hostkey_src=assh ;; /var/lib/sshd/*) echo hostkey_src=throwaway ;; *) echo hostkey_src=none ;; esac
[ -s /run/assh/host-cert.pub ] && echo hostcert=yes || echo hostcert=no
echo assh_slot=$(sudo journalctl -b -u assh-agent -o cat | sed -n "s/.* through slot \([0-9]*\)\$/\1/p" | tail -1)
echo machine_id=$(cat /etc/machine-id)
# The PCR values the agent recorded at its start (which slot 0 PCR differs between boots).
echo pcrs=$(sudo cat /run/assh/agent.pcrs.json 2>/dev/null | tr -d " \n")
echo identity=$(sudo cat /run/safespace/identity/released 2>/dev/null | tr "\n" , | sed "s/,\$//")
echo identity_created=$(sudo dmesg | grep -c "safespace-identity: assigned to")
# What a login shows (the first line, colours stripped), and the key ID of the
# certificate served (the slot it was certified through).
echo login=$(script -qc "bash -lic true" /dev/null 2>/dev/null | head -1 | sed "s/\x1b\[[0-9;]*m//g" | tr -d "\r" | tr " " _)
echo cert_id=$(ssh-keygen -Lf /run/assh/host-cert.pub 2>/dev/null | sed -n "s/.*Key ID: \"\(.*\)\"/\1/p" | tr " " _)
# The TPM'"'"'s active PCR banks (sysfs).
echo tpm_banks=$(cd /sys/class/tpm/tpm0 2>/dev/null && ls -d pcr-* 2>/dev/null | sed "s/^pcr-//" | tr "\n" , | sed "s/,\$//")
'
probe() { vm_ssh "$PROBE" >"$LOGS/$1.probe" 2>&1; }
val() { sed -n "s/^$2=//p" "$LOGS/$1.probe" 2>/dev/null | head -1; }

# expect NAME KEY=VALUE...: every key has the value (VALUE* = starts with)
expect() {
	local name=$1 kv k v got bad=""; shift
	for kv in "$@"; do
		k=${kv%%=*} v=${kv#*=} got=$(val "$name" "$k")
		if [[ $v == *'*' ]]; then [[ $got == "${v%\*}"* ]] || bad+="$k=$got (want $v) "
		else [[ $got == "$v" ]] || bad+="$k=$got (want $v) "; fi
	done
	if [[ -z $bad ]]; then result PASS "$name"; else result FAIL "$name" "$bad"; return 1; fi
}

COMMON=(root=/dev/mapper/root,erofs verity=verified state=running failed=0 lockdown=integrity slim=ok)
SEALED=(secure_boot=enabled* path_var=set usb_bootdev=1 "${COMMON[@]}")
STICK=$RUN/stick.raw

step_stick() {
	local want; read -ra want <<<"$(looks "${COMBOS[0]}")"
	if vm_start stick "$STICK"; then
		probe stick
		expect stick path_var=set usb_bootdev=1 netroot=0 stick_ro=1 hostkey_src=throwaway "${COMMON[@]}" "${want[@]}"
	else
		result FAIL stick "$ERR"
	fi
	vm_stop stick
}

step_net() {
	local want; read -ra want <<<"$(looks "${COMBOS[0]}")"
	if vm_start net --netboot --tree "$RUN/share" --no-server --tpm; then
		probe net
		expect net path_var=unset usb_bootdev=0 netroot=1 "${COMMON[@]}" "${want[@]}"
	else
		result FAIL net "$ERR"
	fi
	vm_stop net
}

step_net_sb() {
	local want; read -ra want <<<"$(looks "${COMBOS[0]}")"
	if vm_start net-sb --netboot --tree "$RUN/share" --no-server --secure-boot --tpm; then
		probe net-sb
		expect net-sb secure_boot=enabled* path_var=unset netroot=1 "${COMMON[@]}" "${want[@]}"
	else
		result FAIL net-sb "$ERR"
	fi
	vm_stop net-sb
}

# Setup Mode, safespace seal, boot sealed. The sealed variables go to
# $RUN/sealed-vars.fd only if all of it passed: the select and identity steps
# start from them. Without a TPM, as the stick step: a sealed boot with one would
# seal a machine-id to it, which no identity step's TPM could open (every other
# step boots with a TPM, as the machines do).
step_seal() {
	if ! vm_start seal-setup "$STICK" --setup-mode; then
		result FAIL seal "$ERR"
		vm_stop seal-setup
		return
	fi
	probe seal-setup
	vm_ssh 'echo YES | sudo safespace seal' >"$LOGS/seal.log" 2>&1
	if [[ $(val seal-setup secure_boot) != *setup* ]] || ! grep -q "Sealed." "$LOGS/seal.log"; then
		result FAIL seal "not in Setup Mode or safespace seal failed (see ${LOGS#"$REPO"/}/seal.log)"
		vm_stop seal-setup
		return
	fi
	vm_stop seal-setup
	if vm_start seal "$STICK" --sealed; then
		probe seal
		expect seal "${SEALED[@]}" && cp "$WORK/sealed-vars.fd" "$RUN/sealed-vars.fd"
	else
		result FAIL seal "$ERR"
	fi
	vm_stop seal
}

# What a combination must look like from inside: its name (the initrd's and
# the root's own, os-release, the login banner), its groups, the docker command
# exactly with the docker group.
looks() { # "name:group+group"
	local n=${1%%:*} g=${1#*:} d=no
	[[ +$g+ == *+docker+* ]] && d=yes
	echo "combination=$n" "named=$n" "pretty=safespace_${VERSION}_$n" "issue=safespace_${VERSION}_${n}_*" "groups=${g//+/,}" "docker=$d"
}
# sel_boot NAME COMBO COMMAND-AFTER: boot the stick on the step's sealed
# variables, check, run a command, power off
sel_boot() {
	local name=$1 combo=$2 cmd=$3 want
	read -ra want <<<"$(looks "$combo")"
	if vm_start "$name" "$STICK" --sealed --tpm; then
		probe "$name"
		expect "$name" "${want[@]}" "${SEALED[@]}"
		vm_ssh "$cmd" >"$LOGS/$name.select.log" 2>&1 || result FAIL "$name" "'$cmd' failed (see ${LOGS#"$REPO"/}/$name.select.log)"
	else
		result FAIL "$name" "$ERR"
	fi
	vm_stop "$name"
}

# safespace select on one firmware, one boot after the other: no selection ->
# the first; set SECOND -> SECOND; once FIRST -> FIRST for one boot; SECOND
# again (persistent); clear -> the first again.
step_select() {
	local first=${COMBOS[0]%%:*} second
	cp "$RUN/sealed-vars.fd" "$WORK/sealed-vars.fd"
	if ((${#COMBOS[@]} < 2)); then
		sel_boot select-default "${COMBOS[0]}" 'sudo safespace select'
		return
	fi
	second=${COMBOS[1]%%:*}
	sel_boot select-default "${COMBOS[0]}" "sudo safespace select && sudo safespace select $second"
	sel_boot "select-$second" "${COMBOS[1]}" "sudo safespace select && sudo safespace select $first --once"
	sel_boot select-once "${COMBOS[0]}" 'sudo safespace select'
	sel_boot select-persistent "${COMBOS[1]}" 'sudo safespace select --default'
	sel_boot select-cleared "${COMBOS[0]}" 'sudo safespace select'
}

# Every further combination in a VM of its own, on a copy of the sealed
# variables with SafespaceSelectOnce=<name> written offline (safespace select
# itself is step_select's): the initrd must open that root and delete the
# variable.
step_select_once() { # INDEX
	local combo=${COMBOS[$1]} n=${COMBOS[$1]%%:*}
	printf '{"version":2,"variables":[{"name":"SafespaceSelectOnce","guid":"%s","attr":7,"data":"%s"}]}\n' \
		"$SELECT_GUID" "$(printf %s "$n" | od -An -tx1 | tr -d ' \n')" >"$WORK/select-once.json"
	if ! virt-fw-vars -i "$RUN/sealed-vars.fd" -o "$WORK/sealed-vars.fd" --set-json "$WORK/select-once.json" >"$LOGS/select-$n.vars.log" 2>&1; then
		result FAIL "select-$n" "could not write SafespaceSelectOnce (see ${LOGS#"$REPO"/}/select-$n.vars.log)"
		return
	fi
	sel_boot "select-$n" "$combo" "! test -e /sys/firmware/efi/efivars/SafespaceSelectOnce-$SELECT_GUID"
}

# The machine identity (SECURITY.md, "Machine identity"), on a TPM of its own (swtpm,
# test-vm.sh --tpm: its state stays in the step's work directory, like a real TPM)
# and a copy of the sealed firmware of seal, one boot after the other.
ID_GUID=8a3e6c1d-4b2f-4e9a-b7d5-1c0f9e2a6b34
# The test's PIN and lockout authorization (throwaway, like the test user).
ID_PIN=test-pin-4711 ID_LOCKOUT=test-lockout-0815
# From the running root: unseal the machine-id slot with the UKI's signatures, then
# again after extending PCR 15 with NAME (what an attacker in another combination does).
id_attack() { # NAME
	vm_ssh 'sudo sh -c "tail -c +5 /sys/firmware/efi/efivars/SafespaceIdMachine-'"$ID_GUID"'" >/tmp/id.cred
		try() { sudo systemd-creds decrypt --tpm2-signature=/run/systemd/tpm2-pcr-signature.json --name=safespace-machine-id /tmp/id.cred - >/dev/null 2>&1 && echo yes || echo no; }
		echo unsealed=$(try)
		sudo /usr/lib/systemd/systemd-pcrextend --pcr=15 "safespace-combination:'"$1"'" >/dev/null 2>&1
		echo unsealed_extended=$(try)'
}
# A client that trusts the machine only through the CA ($WORK/ca_known_hosts:
# '@cert-authority * <CA key>'), as README tells clients to: ca_login=yes|no.
ca_login() {
	ssh -i "$REPO/$VM/id_ed25519" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes \
		-o UserKnownHostsFile="$WORK/ca_known_hosts" -o GlobalKnownHostsFile=/dev/null -o BatchMode=yes \
		-o LogLevel=error -o ConnectTimeout=5 -p "$PORT" tester@127.0.0.1 true >/dev/null 2>&1 && echo ca_login=yes || echo ca_login=no
}
# safespace in the VM with the test's secrets on file descriptors 3 and 4.
id_safespace() { # ARGS...
	vm_ssh "sudo bash -c 'safespace $* 3< <(printf %s \"\$0\") 4< <(printf %s \"\$1\")' $ID_PIN $ID_LOCKOUT"
}
id_boot() { # NAME TEST-VM-ARGS...: boot on the step's firmware and TPM, probe (and the CA login)
	local n=$1; shift
	# ID_TPM: the TPM option (--tpm-banks sha1 for a TPM like the T450s's).
	if vm_start "$n" "$@" --sealed ${ID_TPM:---tpm}; then probe "$n"; ca_login >>"$LOGS/$n.probe"; return 0; fi
	result FAIL "$n" "$ERR"; vm_stop "$n"; return 1
}
# id_check NAME DESCRIPTION CONDITION...: PASS if every [[ ]] condition holds
id_check() {
	local n=$1 d=$2; shift 2
	if bash -c "$*"; then result PASS "$n" "$d"; else result FAIL "$n" "$d"; fi
}
# id_run NAME DESCRIPTION PATTERN COMMAND...: the command's output (to the log) has PATTERN
id_run() {
	local n=$1 d=$2 p=$3; shift 3
	"$@" >"$LOGS/$n.log.out" 2>&1
	if grep -q -- "$p" "$LOGS/$n.log.out"; then result PASS "$n" "$d"; else result FAIL "$n" "$d (see ${LOGS#"$REPO"/}/$n.log.out)"; fi
}
# The combinations the identity step uses: the default, the debug one if there is one (another
# combination), the one it moves to.
id_names() {
	local c
	first=${COMBOS[0]%%:*} other="" move=""
	for c in "${COMBOS[@]:1}"; do
		[[ ${c#*:} == *+debug ]] && other=${c%%:*}
		[[ ${c#*:} != *+debug && -z $move ]] && move=${c%%:*}
	done
	[[ -n $other ]] || other=${COMBOS[1]%%:*}
	[[ -n $move ]] || move=$other
}
# The identity step's first part (30-identity): the first sealed boot and the
# creation, then the certified boot. What it leaves - the TPM, the firmware
# variables, the client's @cert-authority line, the machine-id - is where every
# further part starts from, each on a copy of its own, side by side (id_branch).
step_identity() {
	local first other move mid
	id_names
	cp "$RUN/sealed-vars.fd" "$WORK/sealed-vars.fd"
	: >"$WORK/ca_known_hosts"
	# 1. The first sealed boot with a TPM: the machine-id is created; no CA yet, so
	# aSSH's temporary key, the state recorded. identity create in this boot:
	# the CA, approved for this state; still the temporary key (window closed).
	id_boot identity-first "$STICK" || return
	id_run identity-create "identity create: CA created, this state approved (PIN, lockout authorization)" "identity is created" id_safespace identity create --pin-fd 3 --lockout-auth-fd 4
	sed -n 's/^ *\(@cert-authority .*\)$/\1/p' "$LOGS/identity-create.log.out" | head -1 >"$WORK/ca_known_hosts"
	ca_login >>"$LOGS/identity-first.probe"
	vm_stop identity-first
	expect identity-first combination="$first" identity=SafespaceIdMachine identity_created=1 hostkey_src=assh hostcert=no ca_login=no "${SEALED[@]}" || return
	[[ -s $WORK/ca_known_hosts ]] || { result FAIL identity-create "no @cert-authority line in the output"; return; }
	mid=$(val identity-first machine_id)
	# 2. The next boot: certified through slot 0, the client trusts it; an agent
	# restart gets no certificate (the window is closed); no unseal from the root.
	id_boot identity-certified "$STICK" || return
	id_run identity-show "identity: certified through slot 0" "certified by the CA through slot 0" vm_ssh "safespace identity"
	id_run identity-approve0 "identity approve with slot 0 met: nothing to approve" "nothing to approve" id_safespace identity approve --pin-fd 3
	id_attack "$first" >"$LOGS/identity-certified.attack" 2>&1
	# The restart: sshd restarts with it (PartOf), the client that trusts the CA
	# refuses the temporary key, the state of the boot's first start is kept.
	vm_ssh 'sudo sha256sum </run/assh/agent.pcrs.json; sudo systemctl restart assh-agent; sudo journalctl -b -u assh-agent -o cat | sed -n "/^Starting/,\$p" | tail -n +2; sudo sha256sum </run/assh/agent.pcrs.json' >"$LOGS/identity-restart.log" 2>&1
	{ vm_ssh 'echo ssh_after_restart=yes' 2>/dev/null || echo ssh_after_restart=no; ca_login | sed 's/^/restart_/'; } >"$LOGS/identity-restart.probe"
	vm_stop identity-certified
	cat "$LOGS/identity-certified.attack" >>"$LOGS/identity-certified.probe"
	expect identity-certified combination="$first" identity=SafespaceIdMachine identity_created=0 hostkey_src=assh hostcert=yes assh_slot=0 ca_login=yes unsealed=no unsealed_extended=no "${SEALED[@]}"
	id_check identity-certified "the same machine-id" "[[ '$(val identity-certified machine_id)' == '$mid' ]]"
	id_check identity-certified "the login says certified through slot 0, the certificate's key ID too" "grep -q '^login=$first:_the_machine.s_identity,_certified_through_slot_0_' '$LOGS/identity-certified.probe' && grep -qx 'cert_id=safespace_slot=0_pcrs=0,2,7,11,15' '$LOGS/identity-certified.probe'"
	id_check identity-restart "an agent restart in the same boot: temporary (window closed), sshd with it, the first start's state kept" "grep -q 'TEMPORARY' '$LOGS/identity-restart.log' && grep -q 'PCR 15 not as approved' '$LOGS/identity-restart.log' && grep -q 'stays in /run/assh/agent.pcrs.json' '$LOGS/identity-restart.log' && [[ \$(grep -E '^[0-9a-f]{64}' '$LOGS/identity-restart.log' | wc -l) == 2 && \$(grep -E '^[0-9a-f]{64}' '$LOGS/identity-restart.log' | sort -u | wc -l) == 1 ]] && grep -qx ssh_after_restart=yes '$LOGS/identity-restart.probe' && grep -qx restart_ca_login=no '$LOGS/identity-restart.probe'"
	echo "$mid" >"$WORK/mid"
}
# A further part of the identity step: a copy of what the first part left.
ID_BASE_KEY=30
id_branch() {
	local base=$RUN/w/$ID_BASE_KEY
	[[ -s $base/mid ]] || { result FAIL "${KEY#*-}" "the identity's first boots failed: nothing to start from"; return 1; }
	cp -r "$base/tpm" "$WORK/" && cp "$base/sealed-vars.fd" "$base/ca_known_hosts" "$WORK/" || return 1
	mid=$(cat "$base/mid")
}
step_identity_other() {
	local first other move mid
	id_names
	id_branch || return
	# 3. Another combination: temporary key, nothing released, identity approve refused.
	id_boot_once "identity-$other" "$other" || return
	id_run "identity-$other-approve" "identity approve in another combination: refused (identity move)" "sudo safespace identity move" id_safespace identity approve --pin-fd 3
	id_attack "$first" >"$LOGS/identity-$other.attack" 2>&1
	vm_stop "identity-$other"
	cat "$LOGS/identity-$other.attack" >>"$LOGS/identity-$other.probe"
	expect "identity-$other" combination="$other" identity= identity_created=0 hostkey_src=assh hostcert=no assh_slot= ca_login=no unsealed=no unsealed_extended=no "${SEALED[@]}"
	id_check "identity-$other" "another machine-id" "[[ '$(val "identity-$other" machine_id)' != '$mid' ]]"
	id_check "identity-$other" "the login says TEMPORARY host key" "grep -q '^login=$other:_TEMPORARY_host_key' '$LOGS/identity-$other.probe'"
}
step_identity_net() {
	local first other move mid
	id_names
	id_branch || return
	# 4. Over the network, same firmware and TPM. test-vm.sh starts OVMF with other
	# settings for it (fw_cfg: HTTP boot only, the boot order), and PCR 0 differs
	# (seen: 0 alone, 2/7/11/15 equal): slot 1 certifies; identity approve (PIN) gives it
	# slot 0 too.
	id_boot identity-net --netboot --tree "$RUN/share" --no-server || return
	id_run identity-net-approve "identity approve the network boot (PIN)" "next boot certifies through slot 0" id_safespace identity approve --pin-fd 3
	vm_stop identity-net
	expect identity-net combination="$first" netroot=1 identity=SafespaceIdMachine hostcert=yes assh_slot=1 ca_login=yes secure_boot=enabled* "${COMMON[@]}"
}
step_identity_pcr2() {
	local first other move mid
	id_names
	id_branch || return
	# 5. An option ROM more (PCR 2): slot 1 certifies; identity approve (PIN): slot 0 again.
	# The NIC that brings the ROM is on a network of its own without DHCP (a hub port):
	# a second user network would give the guest a second default route.
	local rom="-netdev hubport,id=rom,hubid=9 -device e1000e,netdev=rom"
	VM_QEMU_EXTRA=$rom id_boot identity-pcr2 "$STICK" || return
	id_run identity-pcr2-approve "identity approve after slot 1 (PIN)" "next boot certifies through slot 0" id_safespace identity approve --pin-fd 3
	vm_stop identity-pcr2
	expect identity-pcr2 combination="$first" identity=SafespaceIdMachine hostcert=yes assh_slot=1 ca_login=yes cert_id=safespace_slot=1_pcrs=7,15 "${SEALED[@]}"
	id_check identity-pcr2 "the login says certified through slot 1" "grep -q '^login=$first:_the_machine.s_identity,_certified_through_slot_1:' '$LOGS/identity-pcr2.probe'"
	VM_QEMU_EXTRA=$rom id_boot identity-pcr2-approved "$STICK" || return
	vm_stop identity-pcr2-approved
	expect identity-pcr2-approved combination="$first" hostcert=yes assh_slot=0 ca_login=yes "${SEALED[@]}"
}
step_identity_pcr7() {
	local first other move mid
	id_names
	id_branch || return
	# 6. Another certificate in db (PCR 7, every slot reads it): temporary, nothing
	# released; identity move (no name: this boot's state, PIN, a new generation) keeps the
	# identity here: the next boot certified, with a new machine-id (the machine's is
	# sealed to the old PCR 7).
	cp "$WORK/sealed-vars.fd" "$WORK/sealed-vars.keep"
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=extra-db/ -keyout "$WORK/extra.key" -out "$WORK/extra.pem" 2>/dev/null &&
		virt-fw-vars -i "$WORK/sealed-vars.keep" -o "$WORK/sealed-vars.fd" --add-db 11111111-2222-3333-4444-555555555555 "$WORK/extra.pem" >"$LOGS/identity-pcr7.vars.log" 2>&1 ||
		{ result FAIL identity-pcr7 "could not change db (see ${LOGS#"$REPO"/}/identity-pcr7.vars.log)"; return; }
	id_boot identity-pcr7 "$STICK" || return
	id_run identity-pcr7-move "identity move after a Secure Boot change (PIN)" "the identity is $first's" id_safespace identity move --yes --pin-fd 3
	vm_stop identity-pcr7
	expect identity-pcr7 combination="$first" identity= hostcert=no ca_login=no "${SEALED[@]}"
	id_boot identity-pcr7-moved "$STICK" || return
	vm_stop identity-pcr7-moved
	expect identity-pcr7-moved combination="$first" identity=SafespaceIdMachine identity_created=1 hostcert=yes assh_slot=0 ca_login=yes "${SEALED[@]}"
	id_check identity-pcr7-moved "a new machine-id" "[[ '$(val identity-pcr7-moved machine_id)' != '$mid' ]]"
}
step_identity_move() {
	local first other move mid
	id_names
	id_branch || return
	# 7. Moved with the selection: from the certified default, safespace select
	# $move with a wrong PIN selects nothing; with the PIN it moves the identity
	# (a new generation: $move's state approved before it is booted) and selects
	# $move; the next boot is $move's, certified at once, with the same machine-id;
	# wrong PINs lock out.
	id_boot identity-move-from "$STICK" || return
	vm_ssh "sudo bash -c 'safespace select $move --pin-fd 3 3< <(printf wrong-pin); echo exit=\$?; safespace select'" >"$LOGS/identity-move-wrong.out" 2>&1
	id_check identity-move-wrong "safespace select $move with a wrong PIN: nothing selected" "grep -q 'nothing selected: the identity did not move' '$LOGS/identity-move-wrong.out' && grep -qx 'exit=1' '$LOGS/identity-move-wrong.out' && grep -q '^preselected: *$first' '$LOGS/identity-move-wrong.out'"
	id_run identity-move "safespace select $move (PIN): the identity moves, $move selected, without booting it first" "keeps this machine-id" \
		vm_ssh "sudo bash -c 'safespace select $move --pin-fd 3 3< <(printf %s \"\$0\") && safespace select' $ID_PIN"
	vm_stop identity-move-from
	expect identity-move-from combination="$first" hostcert=yes assh_slot=0 ca_login=yes "${SEALED[@]}"
	id_boot "identity-moved-$move" "$STICK" || return
	vm_ssh 'for i in 1 2 3; do sudo bash -c "assh ca approve --config /etc/assh/assh.conf --pin-fd 3 3< <(printf wrong-pin)"; done; sudo bash -c "assh ca approve --config /etc/assh/assh.conf --pin-fd 3 3< <(printf %s \"\$0\")" '"$ID_PIN" >"$LOGS/identity-lockout.log" 2>&1
	vm_stop "identity-moved-$move"
	expect "identity-moved-$move" combination="$move" identity=SafespaceIdMachine identity_created=1 hostcert=yes assh_slot=0 ca_login=yes "${SEALED[@]}"
	id_check "identity-moved-$move" "the same machine-id" "[[ '$(val "identity-moved-$move" machine_id)' == '$mid' ]]"
	id_check identity-lockout "3 wrong PINs: the right one is locked out too" "grep -q 'wrong PIN' '$LOGS/identity-lockout.log' && tail -1 '$LOGS/identity-lockout.log' | grep -q 'locked out after too many wrong PINs'"
	# 8. The default afterwards: its approvals are revoked.
	id_boot_once identity-after-move "$first" || return
	vm_stop identity-after-move
	expect identity-after-move combination="$first" identity= hostcert=no ca_login=no "${SEALED[@]}"
}
step_identity_clear() {
	local first other move mid old
	id_names
	id_branch || return
	# 11. Cleared in the certified default: identity says none; identity create in
	# the same boot (this boot's recorded state); the next boot certified by the new
	# CA, with a new machine-id; the old CA's line no longer logs in.
	old=$(cat "$WORK/ca_known_hosts")
	id_boot identity-clear "$STICK" || return
	id_run identity-clear-run "identity clear" "the identity is removed" id_safespace identity clear --yes
	vm_ssh 'sudo safespace identity; ls /sys/firmware/efi/efivars | grep -c -E "^(SAFEasshCA|SafespaceIdMachine)-" || true' >"$LOGS/identity-clear.out" 2>&1
	id_run identity-recreate "identity create after identity clear" "identity is created" id_safespace identity create --pin-fd 3 --lockout-auth-fd 4
	sed -n 's/^ *\(@cert-authority .*\)$/\1/p' "$LOGS/identity-recreate.log.out" | head -1 >"$WORK/ca_known_hosts"
	vm_stop identity-clear
	id_check identity-clear "nothing left of the identity: identity says none" "grep -q 'identity:      none yet' '$LOGS/identity-clear.out' && tail -1 '$LOGS/identity-clear.out' | grep -qx 0"
	id_boot identity-recreated "$STICK" || return
	printf '%s\n' "$old" >"$WORK/ca_known_hosts.old"
	cp "$WORK/ca_known_hosts" "$WORK/ca_known_hosts.new" && cp "$WORK/ca_known_hosts.old" "$WORK/ca_known_hosts"
	ca_login | sed 's/^/old_/' >>"$LOGS/identity-recreated.probe"
	cp "$WORK/ca_known_hosts.new" "$WORK/ca_known_hosts"
	vm_stop identity-recreated
	expect identity-recreated combination="$first" identity=SafespaceIdMachine identity_created=1 hostcert=yes assh_slot=0 ca_login=yes old_ca_login=no "${SEALED[@]}"
	id_check identity-recreated "a new CA and a new machine-id" "[[ -s '$WORK/ca_known_hosts' && \"\$(cat '$WORK/ca_known_hosts')\" != '$old' && '$(val identity-recreated machine_id)' != '$mid' ]]"
}
step_identity_fails() {
	local first other move mid
	id_names
	id_branch || return
	# 9. The agent fails (SAFEasshCA damaged, written into the firmware variables):
	# sshd still comes up, with the throwaway key, and says why.
	printf '{"version":2,"variables":[{"name":"SAFEasshCA","guid":"24415b90-39be-45c0-a9a3-d547ebe28ea0","attr":7,"data":"%s"}]}\n' \
		"$(printf %s '{broken' | od -An -tx1 | tr -d ' \n')" >"$WORK/broken.json"
	cp "$WORK/sealed-vars.fd" "$WORK/sealed-vars.ok"
	virt-fw-vars -i "$WORK/sealed-vars.ok" -o "$WORK/sealed-vars.fd" --set-json "$WORK/broken.json" >"$LOGS/identity-broken.vars.log" 2>&1 ||
		{ result FAIL identity-agent-fails "could not damage SAFEasshCA (see ${LOGS#"$REPO"/}/identity-broken.vars.log)"; return; }
	id_boot identity-agent-fails "$STICK" || return
	vm_ssh 'sudo journalctl -b -u sshd-hostkeys -u assh-agent -o cat' >"$LOGS/identity-agent-fails.journal" 2>&1
	vm_stop identity-agent-fails
	# assh-agent failed: the one failed unit, the system degraded.
	expect identity-agent-fails combination="$first" hostkey_src=throwaway ca_login=no secure_boot=enabled* path_var=set usb_bootdev=1 \
		root=/dev/mapper/root,erofs verity=verified state=degraded failed=1 lockdown=integrity slim=ok
	# StandardOutput=journal+console: the journal here (the VM's /dev/console is its screen).
	id_check identity-agent-fails "the fallback says the host key is a throwaway one, and why" "grep -q 'ssh host key: THROWAWAY (aSSH did not start' '$LOGS/identity-agent-fails.journal' && grep -q 'SAFEasshCA' '$LOGS/identity-agent-fails.journal'"
}
step_identity_sha1() {
	local first other move mid
	id_names
	# 10. A TPM with the SHA-1 bank only (the T450s's firmware), new, on the sealed
	# variables without an identity. SHA-1 not allowed: no machine-id, aSSH's
	# temporary key and nothing recorded; tpm sha1 on; the next boot gives the
	# machine-id, identity create, the boot after is certified through slot 0;
	# tpm sha1 off: the boot after has neither.
	local ID_TPM="--tpm-banks sha1"
	cp "$RUN/sealed-vars.fd" "$WORK/sealed-vars.fd"
	: >"$WORK/ca_known_hosts"
	id_boot identity-sha1-off "$STICK" || return
	vm_ssh 'sudo dmesg | grep safespace-identity; sudo journalctl -b -u assh-agent -o cat; sudo safespace' >"$LOGS/identity-sha1-off.out" 2>&1
	id_run identity-sha1-on "tpm sha1 on" "SHA-1 is allowed: from the next boot" id_safespace tpm sha1 on
	vm_stop identity-sha1-off
	expect identity-sha1-off combination="$first" tpm_banks=sha1 identity= identity_created=0 hostkey_src=assh hostcert=no pcrs= ca_login=no "${SEALED[@]}" || return
	id_check identity-sha1-off "SHA-1 not allowed: the initrd and the agent say so, identity too" "grep -q 'SHA-1 is not allowed: no identity this boot' '$LOGS/identity-sha1-off.out' && grep -q 'none can be made: the TPM.s only active PCR bank is sha1, and sha1 is not allowed' '$LOGS/identity-sha1-off.out' && grep -q 'PCR bank:      none: the TPM has the SHA-1 bank only' '$LOGS/identity-sha1-off.out'"
	id_boot identity-sha1-first "$STICK" || return
	id_run identity-sha1-create "identity create on SHA-1" "identity is created" id_safespace identity create --pin-fd 3 --lockout-auth-fd 4
	sed -n 's/^ *\(@cert-authority .*\)$/\1/p' "$LOGS/identity-sha1-create.log.out" | head -1 >"$WORK/ca_known_hosts"
	vm_stop identity-sha1-first
	expect identity-sha1-first combination="$first" tpm_banks=sha1 identity=SafespaceIdMachine identity_created=1 hostkey_src=assh hostcert=no ca_login=no "${SEALED[@]}" || return
	id_check identity-sha1-first "the recorded state is SHA-1's" "[[ '$(val identity-sha1-first pcrs)' == *'\"bank\":\"sha1\"'* ]]"
	mid=$(val identity-sha1-first machine_id)
	id_boot identity-sha1-certified "$STICK" || return
	vm_ssh 'sudo safespace' >"$LOGS/identity-sha1-certified.out" 2>&1
	id_attack "$first" >"$LOGS/identity-sha1-certified.attack" 2>&1
	id_run identity-sha1-forbid "tpm sha1 off" "SHA-1 is forbidden: from the next boot" id_safespace tpm sha1 off
	vm_stop identity-sha1-certified
	cat "$LOGS/identity-sha1-certified.attack" >>"$LOGS/identity-sha1-certified.probe"
	expect identity-sha1-certified combination="$first" tpm_banks=sha1 identity=SafespaceIdMachine identity_created=0 hostkey_src=assh hostcert=yes assh_slot=0 ca_login=yes unsealed=no unsealed_extended=no "${SEALED[@]}"
	id_check identity-sha1-certified "the same machine-id; identity names the SHA-1 bank" "[[ '$(val identity-sha1-certified machine_id)' == '$mid' ]] && grep -q 'PCR bank:      sha1' '$LOGS/identity-sha1-certified.out'"
	id_boot identity-sha1-forbidden "$STICK" || return
	vm_ssh 'sudo dmesg | grep safespace-identity; sudo journalctl -b -u assh-agent -o cat' >"$LOGS/identity-sha1-forbidden.out" 2>&1
	vm_stop identity-sha1-forbidden
	expect identity-sha1-forbidden combination="$first" identity= hostkey_src=assh hostcert=no ca_login=no "${SEALED[@]}"
	id_check identity-sha1-forbidden "tpm sha1 off: neither the machine-id nor a certificate" "grep -q 'SHA-1 is not allowed: no identity this boot' '$LOGS/identity-sha1-forbidden.out' && grep -q 'the CA reads sha1, and sha1 is no longer allowed' '$LOGS/identity-sha1-forbidden.out'"
}

# Boot NAME once in COMBINATION: the selection written into the step's firmware
# variables (virt-fw-vars), as select does it; the initrd deletes it.
id_boot_once() { # NAME COMBINATION
	local n=$1
	cp "$WORK/sealed-vars.fd" "$WORK/sealed-vars.once"
	printf '{"version":2,"variables":[{"name":"SafespaceSelectOnce","guid":"%s","attr":7,"data":"%s"}]}\n' \
		"$SELECT_GUID" "$(printf %s "$2" | od -An -tx1 | tr -d ' \n')" >"$WORK/once.json"
	virt-fw-vars -i "$WORK/sealed-vars.once" -o "$WORK/sealed-vars.fd" --set-json "$WORK/once.json" >"$LOGS/$n.vars.log" 2>&1 ||
		{ result FAIL "$n" "could not write SafespaceSelectOnce (see ${LOGS#"$REPO"/}/$n.vars.log)"; return 1; }
	id_boot "$n" "$STICK"
}

# job KEY FUNCTION ARGS...: run a step in the background, at most $JOBS at a time.
# KEY orders the report and names the step's work directory (short: qga.sock is a
# unix socket).
JOB_PID=""
job() {
	local key=$1; shift
	while (($(jobs -rp | wc -l) >= JOBS)); do wait -n; done
	(
		KEY=$key WORK=$RUN/w/${key%%-*}
		mkdir -p "$WORK"
		trap vm_kill EXIT
		"$@"
	) &
	JOB_PID=$!
}

if wants stick || wants seal; then
	log "assembling the stick image"
	(source "$REPO/lib/stick.sh"; stick_write "$STICK" "$RUN/share") >"$LOGS/stick-image.log" 2>&1 ||
		die "could not assemble the stick image (see ${LOGS#"$REPO"/}/stick-image.log)"
fi
if wants net || wants net-sb || wants identity; then
	python3 -m http.server "$PORT_HTTP" --bind 127.0.0.1 --directory "$RUN/share" >"$LOGS/http.log" 2>&1 &
	HTTP_PID=$!
	disown "$HTTP_PID"
	for _ in $(seq 30); do curl -fsS -o /dev/null "http://127.0.0.1:$PORT_HTTP/boot.efi" 2>/dev/null && break; sleep 0.3; done
fi

# How many VMs at once: a network boot holds its root in RAM (test-vm.sh: largest
# root + 2 GiB), each VM has 2 CPUs; at most 4.
if [[ -z $JOBS ]]; then
	root_mib=$(($(stat -c %s "$DIR"/root-*.img | sort -n | tail -1) / 1048576))
	avail_mib=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
	JOBS=$((avail_mib / (root_mib + 2560)))
	((JOBS > $(nproc) / 2)) && JOBS=$(($(nproc) / 2))
	((JOBS > 4)) && JOBS=4
	((JOBS < 1)) && JOBS=1
fi
log "booting, up to $JOBS VMs at a time (logs: ${RUN#"$REPO"/})"

# seal first: the select steps wait for it.
wants seal && { job 12-seal step_seal; SEAL_PID=$JOB_PID; }
wants stick && job 10-stick step_stick
wants net && job 11-net step_net
wants net-sb && job 13-net-sb step_net_sb
if wants select || wants identity; then
	wait "$SEAL_PID" 2>/dev/null
fi
if wants identity; then
	if [[ ! -f $RUN/sealed-vars.fd ]]; then
		KEY=30-identity result FAIL identity "no sealed firmware variables (the step seal failed)"
	else
		job 30-identity step_identity
		ID_PID=$JOB_PID
		# A TPM of its own, from the sealed variables: beside the rest.
		job 37-identity-sha1 step_identity_sha1
	fi
fi
if wants select; then
	if [[ ! -f $RUN/sealed-vars.fd ]]; then
		KEY=20-select result FAIL select "no sealed firmware variables (the step seal failed)"
	else
		job 20-select step_select
		for ((i = 2; i < ${#COMBOS[@]}; i++)); do
			job "$((19 + i))-select-${COMBOS[i]%%:*}" step_select_once "$i"
		done
	fi
fi
# The identity's further parts start from what its first part left, side by side.
if [[ -n ${ID_PID:-} ]]; then
	wait "$ID_PID"
	job 31-identity-other step_identity_other
	job 32-identity-net step_identity_net
	job 33-identity-pcr2 step_identity_pcr2
	job 34-identity-pcr7 step_identity_pcr7
	job 35-identity-move step_identity_move
	job 36-identity-fails step_identity_fails
	job 38-identity-clear step_identity_clear
fi
wait

# debug adds packages, nothing else: a combination that is the first plus debug
# must have the first one's setuid/setgid files, file capabilities and enabled units.
if wants select; then
	KEY=90-debug
	for c in "${COMBOS[@]:1}"; do
		[[ ${c#*:} == "${COMBOS[0]#*:}+debug" ]] || continue
		n=select-${c%%:*} bad=""
		for k in suid caps enabled; do
			[[ -n $(val select-default "$k") && $(val "$n" "$k") == "$(val select-default "$k")" ]] ||
				bad+="$k=$(val "$n" "$k") (want $(val select-default "$k")) "
		done
		if [[ -z $bad ]]; then result PASS "$n-surface"; else result FAIL "$n-surface" "$bad"; fi
	done
fi

# --- report --------------------------------------------------------------------------------

# The stick image is large and can be assembled again; the logs stay.
rm -f "$STICK"
printf '\n\e[1mbuild %s\e[0m\n' "$BUILD"
cat "$RUN/results"/* | sed 's/^/  /'
printf 'logs: %s\n' "${RUN#"$REPO"/}"
! grep -qv '^PASS' "$RUN/results"/*
