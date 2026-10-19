#!/usr/bin/env bash
# Build a diagnostic stick image that boots a UKI layer by layer, to find out
# why a machine resets or hangs on the real stick. No root needed.
#
#   ./hwtest-image.sh [UKI]        (default: the newest usb build's UKI, mkosi.output/usb/*/*.efi)
#   sudo wipefs -a /dev/sdX
#   sudo dd if=mkosi.test/hwtest.img of=/dev/sdX bs=4M conv=fsync oflag=direct status=progress
#
# The stick boots into a systemd-boot menu (waits for a choice):
#   1 the UKI exactly as built           -> runs until "waiting for root"
#   2 UKI without the microcode section  -> same as 1
#   3 systemd-stub + kernel only         -> kernel panic "Unable to mount root" = OK
#   4 kernel only, no stub               -> kernel panic = OK
#   5 kernel + initrd, no stub           -> initrd starts, "usb-bootdev: waiting"
#   6 kernel + microcode + initrd        -> same as 5
# Entries 3-6 print kernel messages from the start (earlyprintk=efi), so a
# crash shows how far it got. Which entries reset tells the layer: firmware
# (no menu at all), systemd-stub, microcode, initrd size, or the kernel.
# If all entries boot but the real stick does not, the firmware fails to start
# the image the way it is laid out on the real ESP (e.g. a big UKI as
# BOOTX64.EFI, which is why the stick now uses systemd-boot).
# The test files are unsigned: the machine needs Secure Boot off or in Setup Mode.
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }

# Default: the newest usb UKI (a network UKI would load its root over HTTP,
# which says nothing about why this machine will not boot from a medium).
UKI=${1:-$(ls -t "$HERE"/mkosi.output/usb/*/*.efi 2>/dev/null | head -1 || true)}
[[ -n $UKI && -f $UKI ]] || die "no UKI found (mkosi.output/usb/*/*.efi; run: sudo ./build.sh usb)"
STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
BOOT=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
for f in "$STUB" "$BOOT"; do [[ -f $f ]] || die "$f missing (systemd, systemd-ukify)"; done
for cmd in objcopy ukify sfdisk mkfs.fat mcopy; do command -v $cmd >/dev/null || die "missing $cmd"; done

W=$HERE/mkosi.test/hwtest
IMG=$HERE/mkosi.test/hwtest.img
rm -rf "$W" && mkdir -p "$W/tree/EFI/BOOT" "$W/tree/EFI/hwtest" "$W/tree/loader/entries"
log "Taking apart $(basename "$UKI")"
for s in linux initrd ucode cmdline osrel; do
	objcopy -O binary --only-section=.$s "$UKI" "$W/$s.bin" 2>/dev/null || true
done
[[ -s $W/linux.bin && -s $W/initrd.bin ]] || die "$UKI has no .linux/.initrd section"
CL=$(tr -d '\0' <"$W/cmdline.bin")
V="earlyprintk=efi,keep ignore_loglevel panic=0"
T=$W/tree/EFI/hwtest

cp "$BOOT" "$W/tree/EFI/BOOT/BOOTX64.EFI"
cp "$UKI" "$T/full.efi"
ukify build --linux="$W/linux.bin" --initrd="$W/initrd.bin" --cmdline="$CL" \
	--os-release=@"$W/osrel.bin" --stub="$STUB" --output="$T/noucode.efi" >/dev/null
ukify build --linux="$W/linux.bin" --cmdline="$V" --os-release=@"$W/osrel.bin" \
	--stub="$STUB" --output="$T/small.efi" >/dev/null
cp "$W/linux.bin" "$T/linux.efi"
cp "$W/initrd.bin" "$T/initrd.img"
ucode=()
if [[ -s $W/ucode.bin ]]; then
	cp "$W/ucode.bin" "$T/ucode.img"
	ucode=("initrd /EFI/hwtest/ucode.img")
fi

printf 'timeout menu-force\nconsole-mode keep\n' >"$W/tree/loader/loader.conf"
entry() { printf '%s\n' "title $2" "sort-key $1" "${@:3}" >"$W/tree/loader/entries/$1.conf"; }
entry t1 "1 UKI exactly as built" "efi /EFI/hwtest/full.efi"
entry t2 "2 UKI without microcode" "efi /EFI/hwtest/noucode.efi"
entry t3 "3 systemd-stub + kernel only (kernel panic = OK)" "efi /EFI/hwtest/small.efi"
entry t4 "4 kernel only, no stub (kernel panic = OK)" "linux /EFI/hwtest/linux.efi" "options $V"
entry t5 "5 kernel + initrd, no stub, no microcode" "linux /EFI/hwtest/linux.efi" \
	"initrd /EFI/hwtest/initrd.img" "options $CL $V"
entry t6 "6 kernel + microcode + initrd, no stub" "linux /EFI/hwtest/linux.efi" \
	"${ucode[@]}" "initrd /EFI/hwtest/initrd.img" "options $CL $V"

log "Writing $IMG"
rm -f "$IMG"
truncate -s 514M "$IMG"
printf 'label: gpt\nstart=2048, size=%d, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"\n' \
	$((512 * 2048)) | sfdisk -q "$IMG"
# Same FAT as the real stick: FAT32, 512-byte sectors.
mkfs.fat -F 32 -S 512 -n HWTEST --offset 2048 "$IMG" $((512 * 1024)) >/dev/null 2>&1
(cd "$W/tree" && mcopy -s -i "$IMG@@1M" EFI loader ::/)
rm -rf "$W"
log "Done. Write it with:"
echo "  sudo wipefs -a /dev/sdX"
echo "  sudo dd if=$IMG of=/dev/sdX bs=4M conv=fsync oflag=direct status=progress"
