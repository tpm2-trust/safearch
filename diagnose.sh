#!/usr/bin/env bash
# Read-only check of a stick/SD card written from a "usb" image (burn.sh):
# ESP + signed UKI, dm-verity root (verified block by block), nothing writable.
# Usage: sudo ./diagnose.sh [--db-cert db.pem] /dev/sdX
#   --db-cert  the db certificate the signatures must verify against (default:
#              the build host's exported db.pem, else a distribution server's
#              /etc/safespace/db.pem); needs sbverify (sbsigntools)
set -uo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
DB_CERT=""
[[ ${1:-} == --db-cert ]] && { DB_CERT=${2:?--db-cert needs a file}; shift 2; }
DISK=${1:?usage: sudo $0 [--db-cert db.pem] /dev/sdX}
if [[ -z $DB_CERT ]]; then
	for f in "$HERE/mkosi.extra/usr/share/safespace/secureboot/db.pem" /etc/safespace/db.pem; do
		[[ -f $f ]] && DB_CERT=$f && break
	done
fi
[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ -b $DISK ]] || { echo "$DISK is not a block device" >&2; exit 1; }

hdr() { printf '\n\e[1;32m== %s\e[0m\n' "$*"; }
ok() { printf '  \e[32mOK\e[0m   %s\n' "$*"; }
bad() { printf '  \e[31mFAIL\e[0m %s\n' "$*"; }

TMP=$(mktemp -d)
cleanup() {
	umount -q "$TMP/esp" "$TMP/root" 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/esp" "$TMP/root"

# Partition by GPT type GUID.
part_by_type() {
	lsblk -lnpo NAME,PARTTYPE "$DISK" | awk -v t="$1" 'tolower($2) == t { print $1; exit }'
}

hdr "Partition table"
sfdisk -d "$DISK"
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,PARTUUID "$DISK"
ESP=$(part_by_type c12a7328-f81f-11d2-ba4b-00a0c93ec93b)
ROOT=$(part_by_type 4f68bce3-e8cd-4db1-96e7-fbcaf984b709)
VERITY=$(part_by_type 2c7357ed-ebd2-46d9-aec1-23d437ec2bf5)
n=$(lsblk -lnpo TYPE "$DISK" | grep -c part)
for p in ESP ROOT VERITY; do
	[[ -n ${!p} ]] && ok "$p partition: ${!p}" || bad "no $p partition"
done
((n == 3)) && ok "exactly 3 partitions, nothing writable on the stick" ||
	bad "$n partitions, expected 3 (ESP, root, root-verity)"
if [[ $(dd if="$DISK" bs=1 skip=32769 count=5 status=none) == CD001 ]]; then
	bad "ISO9660/El Torito header at 32 KiB (CD boot path; image built before ElTorito=no)"
else
	ok "no ISO9660/El Torito header"
fi

hdr "ESP and UKI"
fsck.fat -n "$ESP" | tail -1
fat_sector=$(od -An -tu2 -j11 -N2 "$ESP" | tr -d ' ')
((fat_sector == 512)) && ok "FAT sector size 512" ||
	bad "FAT sector size $fat_sector: many firmwares only read 512-byte FAT sectors on USB sticks"
mount -o ro "$ESP" "$TMP/esp" || { bad "cannot mount ESP"; exit 1; }
find "$TMP/esp" -type f -printf '  %10s  %P\n'
BOOT=$(find "$TMP/esp" -ipath '*/efi/boot/bootx64.efi' | head -1)
[[ -n $BOOT ]] || { bad "no \\EFI\\BOOT\\BOOTX64.EFI: firmware will not find anything to boot"; exit 1; }
if objcopy -O binary --only-section=.sdmagic "$BOOT" /dev/stdout 2>/dev/null | grep -aq 'systemd-boot'; then
	ok "BOOTX64.EFI is systemd-boot ($(($(stat -c %s "$BOOT") / 1024)) KiB)"
else
	bad "BOOTX64.EFI is not systemd-boot (old layout: some firmware resets on a big UKI there)"
fi
mapfile -t ukis < <(find "$TMP/esp" -ipath '*/efi/linux/*.efi')
((${#ukis[@]} == 1)) || { bad "${#ukis[@]} UKIs in \\EFI\\Linux, expected exactly 1"; exit 1; }
UKI=${ukis[0]}
size=$(($(stat -c %s "$UKI") / 1048576))
if ((size <= 100)); then
	ok "UKI ${UKI#"$TMP/esp/"} is $size MiB"
else
	bad "UKI is $size MiB (too big for many firmwares)"
fi
if command -v sbverify >/dev/null; then
	for f in "$BOOT" "$UKI"; do
		echo "  ${f#"$TMP/esp/"}:"
		sbverify --list "$f" 2>&1 | grep -E 'subject|issuer|No signature' | sed 's/^/    /'
		if [[ -n $DB_CERT ]]; then
			sbverify --cert "$DB_CERT" "$f" >/dev/null 2>&1 && ok "signature verifies against $DB_CERT" ||
				bad "NOT signed by the db key in $DB_CERT"
		fi
	done
	[[ -n $DB_CERT ]] || echo "  NOTE no db certificate (--db-cert): signatures listed, not verified"
else
	echo "  NOTE sbverify missing (pacman -S sbsigntools): signatures not checked"
fi
CMDLINE=$(objcopy -O binary --only-section=.cmdline "$UKI" /dev/stdout 2>/dev/null | tr -d '\0')
[[ -n $CMDLINE ]] && ok "cmdline: $CMDLINE" || bad "UKI has no .cmdline section"
[[ $CMDLINE == *usbcore.authorized_default=0* ]] && ok "USB lockdown on the kernel command line"
[[ $CMDLINE == *systemd.volatile=state* ]] && ok "/var is a tmpfs (systemd.volatile=state)" ||
	bad "systemd.volatile=state missing: /var would be on the read-only root"
opts=(systemd.credentials_boot_policy=strict systemd.sysext=0 systemd.confext=0
	rd.systemd.sysext=0 rd.systemd.confext=0)
# systemd-veritysetup opens root, and stops the machine on a corrupted block.
opts+=(systemd.verity_root_options=panic-on-corruption)
for opt in "${opts[@]}"; do
	[[ " $CMDLINE " == *" $opt "* ]] && ok "$opt" || bad "$opt missing from the kernel command line"
done
# Files on the ESP besides the UKI are not verified; systemd-stub would pass
# credentials and extension images from there to the system.
extra=$(cd "$TMP/esp" && find . -type f ! -ipath './efi/boot/bootx64.efi' ! -ipath './efi/linux/*.efi' | sed 's|^\./||')
[[ -z $extra ]] && ok "ESP holds nothing but systemd-boot and the UKI" || { bad "unexpected files on the ESP:"; sed 's/^/       /' <<<"$extra"; }

ROOTHASH=$(tr ' ' '\n' <<<"$CMDLINE" | sed -n 's/^roothash=//p')

hdr "dm-verity root"
if [[ -z $ROOTHASH ]]; then
	bad "no roothash= on the kernel command line"
else
	ok "roothash=$ROOTHASH"
	# The build on this host with that root hash, if any.
	build=$(grep -lx "$ROOTHASH" "$HERE"/mkosi.output/usb/*/*.roothash 2>/dev/null | head -1)
	if [[ -n $build ]]; then
		ok "build: usb/$(basename "$(dirname "$build")") (./build.sh show for its packages)"
	else
		echo "  NOTE build: no build with this root hash on this host"
	fi
	uuid() { sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/' <<<"$1"; }
	want_data=$(uuid "${ROOTHASH:0:32}")
	want_hash=$(uuid "${ROOTHASH: -32}")
	have_data=$(blkid -p -s PART_ENTRY_UUID -o value "$ROOT")
	have_hash=$(blkid -p -s PART_ENTRY_UUID -o value "$VERITY")
	[[ ${have_data,,} == "$want_data" ]] && ok "root partition UUID matches the root hash" ||
		bad "root partition UUID $have_data, expected $want_data"
	[[ ${have_hash,,} == "$want_hash" ]] && ok "verity partition UUID matches the root hash" ||
		bad "verity partition UUID $have_hash, expected $want_hash"
	echo "  verifying every block of root against the root hash (takes a while)..."
	if veritysetup verify "$ROOT" "$VERITY" "$ROOTHASH"; then
		ok "root is exactly what was signed"
	else
		bad "verity verification FAILED: root was modified or the write is damaged"
	fi
fi

hdr "Root content (read-only)"
# udev's blkid must recognise root, or systemd never marks /dev/mapper/root
# ready (99-systemd.rules) and the initrd times out. libblkid does not detect
# erofs with 512-byte blocks.
root_fs=$(blkid -p -s TYPE -o value "$ROOT")
root_bs=$(blkid -p -s FSBLOCKSIZE -o value "$ROOT")
[[ $root_fs == erofs && $root_bs == 4096 ]] && ok "blkid sees erofs, block size 4096" ||
	bad "blkid sees '${root_fs:-nothing}' (block size ${root_bs:-?}): the initrd will wait for /dev/mapper/root forever"
if mount -o ro "$ROOT" "$TMP/root"; then
	ok "root mounted ($(blkid -p -s TYPE -o value "$ROOT"))"
	for f in etc/fstab etc/machine-id; do
		[[ -e $TMP/root/$f ]] && { ok "/$f"; sed 's/^/       /' "$TMP/root/$f"; } || bad "/$f missing"
	done
	for l in home root; do
		[[ -L $TMP/root/$l ]] && ok "/$l -> $(readlink "$TMP/root/$l")" || bad "/$l is not a symlink into /var"
	done
	ls "$TMP/root/etc/ssh/authorized_keys" 2>/dev/null | sed 's/^/  ssh keys for: /'
	ls "$TMP/root/usr/lib/modules" | sed 's/^/  kernel modules: /'
else
	bad "cannot mount root"
fi

hdr "Volatile /var and Docker (inside root)"
if mountpoint -q "$TMP/root"; then
	[[ -d $TMP/root/usr/share/factory/var ]] &&
		ok "factory /var: $(du -sh "$TMP/root/usr/share/factory/var" | cut -f1), homes: $(ls "$TMP/root/usr/share/factory/var/home" 2>/dev/null | tr '\n' ' ')" ||
		bad "no /usr/share/factory/var"
	[[ -z $(ls -A "$TMP/root/var" 2>/dev/null) ]] && ok "/var in root is an empty mount point" ||
		bad "/var in root is not empty"
	sed 's/^/  daemon.json: /' "$TMP/root/etc/docker/daemon.json" 2>/dev/null | tr -d '\n'; echo
	grep -v '^#' "$TMP/root/etc/fstab" 2>/dev/null | grep . | sed 's/^/  fstab: /'
	list=$TMP/root/usr/share/safespace/docker-images/images.list
	if [[ -f $list ]]; then
		grep -v '^#' "$list" | awk '{ print "  shipped image: " $3 " (" $2 ")" }'
	else
		echo "  no Docker images shipped"
	fi
fi
