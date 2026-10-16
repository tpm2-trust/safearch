#!/usr/bin/env bash
# Boot an image in QEMU as a USB stick (xHCI + usb-storage, like real hardware),
# with OVMF. The image is opened with snapshot=on: nothing is written to it.
#
#   ./test-vm.sh [IMAGE] [--secure-boot | --setup-mode | --sealed] [--ssh PORT]
#
# --secure-boot: enforced Secure Boot with only the UKI's own signing
#   certificate in db (taken from the signature, so no root needed). Needs
#   virt-fw-vars (pacman -S virt-firmware).
# --setup-mode: Secure Boot firmware with no keys (Setup Mode), as after
#   "Reset to Setup Mode". Run safespace-seal inside; the firmware variables
#   are kept in mkosi.test/sealed-vars.fd.
# --sealed: boot again with mkosi.test/sealed-vars.fd (after safespace-seal).
# --ssh PORT: forward localhost:PORT to the VM's sshd.
# Console: the QEMU window. A reset ends QEMU (-no-reboot) instead of looping.
# No root needed (user must be able to open /dev/kvm).
# Extra QEMU options via $QEMU_EXTRA, e.g. QEMU_EXTRA='-display none'.
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }

IMAGE="" SB=0 SETUP=0 SEALED=0 SSH_PORT=""
while (($#)); do
	case $1 in
		--secure-boot) SB=1; shift ;;
		--setup-mode) SETUP=1; shift ;;
		--sealed) SEALED=1; shift ;;
		--ssh) SSH_PORT=${2:?--ssh needs a port}; shift 2 ;;
		-h|--help) sed -n '2,18p' "$0"; exit 0 ;;
		-*) die "unknown option $1" ;;
		*) IMAGE=$1; shift ;;
	esac
done
if [[ -z $IMAGE ]]; then
	IMAGE=$(find "$HERE/mkosi.output" "$HERE" -maxdepth 1 -type f \( -name '*.raw.zst' -o -name '*.raw' \) \
		-printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR == 1 { print $2 }' || true)
fi
[[ -n $IMAGE && -f $IMAGE ]] || die "no image found (run: sudo mkosi build)"

OVMF=/usr/share/edk2/x64
[[ -f $OVMF/OVMF_CODE.4m.fd ]] || die "OVMF missing (pacman -S edk2-ovmf)"
WORK=$HERE/mkosi.test
mkdir -p "$WORK"

# Decompress once per image (QEMU needs a raw file).
RAW=$IMAGE
if [[ $IMAGE == *.zst ]]; then
	RAW=$WORK/$(basename "${IMAGE%.zst}")
	if [[ ! -f $RAW || $IMAGE -nt $RAW ]]; then
		rm -f "$WORK"/*.raw
		log "Decompressing $(basename "$IMAGE")"
		zstd -dqf "$IMAGE" -o "$RAW"
	fi
fi

machine=q35,accel=kvm
code=$OVMF/OVMF_CODE.4m.fd
vars=$WORK/vars.fd
cp "$OVMF/OVMF_VARS.4m.fd" "$vars"
extra=()
if ((SB)); then
	command -v virt-fw-vars >/dev/null || die "virt-fw-vars missing (pacman -S virt-firmware)"
	uki=$WORK/uki.efi
	mcopy -n -i "$RAW@@$(($(sfdisk -d "$RAW" | awk -F'[=,]' '/type=C12A7328/ { print $2 }') * 512))" \
		::/EFI/BOOT/BOOTX64.EFI "$uki" 2>/dev/null || die "cannot read the UKI from the ESP (mtools installed?)"
	# Certificate table (PE data directory 4) -> PKCS#7 -> signer certificate.
	python3 -I - "$uki" "$WORK/sig.p7" <<-'EOF'
		import struct, sys
		d = open(sys.argv[1], 'rb').read()
		opt = struct.unpack_from('<I', d, 0x3c)[0] + 24
		dd = opt + (112 if struct.unpack_from('<H', d, opt)[0] == 0x20b else 96)
		off, size = struct.unpack_from('<II', d, dd + 32)
		if not size: sys.exit('UKI is not signed')
		length = struct.unpack_from('<I', d, off)[0]
		open(sys.argv[2], 'wb').write(d[off + 8:off + length])
	EOF
	openssl pkcs7 -inform DER -in "$WORK/sig.p7" -print_certs -out "$WORK/db.pem"
	log "Secure Boot with db = $(openssl x509 -in "$WORK/db.pem" -noout -subject)"
	guid=$(cat /proc/sys/kernel/random/uuid)
	virt-fw-vars -i "$OVMF/OVMF_VARS.4m.fd" -o "$vars" --secure-boot \
		--set-pk "$guid" "$WORK/db.pem" --add-kek "$guid" "$WORK/db.pem" --add-db "$guid" "$WORK/db.pem" >/dev/null 2>&1
	machine+=,smm=on
	code=$OVMF/OVMF_CODE.secboot.4m.fd
	extra+=(-global driver=cfi.pflash01,property=secure,value=on)
fi
if ((SETUP || SEALED)); then
	vars=$WORK/sealed-vars.fd
	if ((SETUP)); then
		cp "$OVMF/OVMF_VARS.4m.fd" "$vars"
		log "Setup Mode: no Secure Boot keys enrolled (run safespace-seal in the VM)"
	else
		[[ -f $vars ]] || die "no $vars (run --setup-mode and safespace-seal first)"
		log "Using the firmware variables written by safespace-seal"
	fi
	machine+=,smm=on
	code=$OVMF/OVMF_CODE.secboot.4m.fd
	extra+=(-global driver=cfi.pflash01,property=secure,value=on)
fi
nic=user,model=virtio-net-pci
[[ -n $SSH_PORT ]] && nic+=,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22

log "Booting $(basename "$RAW") as a USB stick (close the window to stop)"
qemu-system-x86_64 -machine "$machine" "${extra[@]}" -cpu host -smp 2 -m 2048 \
	-drive if=pflash,format=raw,readonly=on,file="$code" \
	-drive if=pflash,format=raw,file="$vars" \
	-device qemu-xhci,id=xhci \
	-drive if=none,id=stick,format=raw,file="$RAW",snapshot=on \
	-device usb-storage,bus=xhci.0,drive=stick,removable=on \
	-nic "$nic" \
	-serial file:"$WORK/serial.log" \
	-no-reboot ${QEMU_EXTRA:-} && rc=0 || rc=$?
log "QEMU exited ($rc). Firmware/serial output: $WORK/serial.log"
