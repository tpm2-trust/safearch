# Assemble a usb stick from a build's (or release's) parts. Sourced by burn.sh
# and test-vm.sh, and by tests/run.sh. Expects die() and log().
#
#   stick_bytes SRC                size of the stick image (from layout.sfdisk)
#   stick_write TARGET SRC [ROOT]  write the stick to TARGET (a block device, or
#                                  an image file, created if missing)
#
# SRC is a directory with layout.sfdisk, systemd-boot.efi, boot.efi,
# root.verity and (unless ROOT is given) root.img. ROOT "-" reads the root
# partition from stdin, so burn.sh can stream it from a server.
#
# What it writes is what systemd-repart laid out in the build:
#   1. the partition table from layout.sfdisk (types, UUIDs derived from the
#      root hash, sizes, attributes)
#   2. the ESP: FAT32 with 512-byte sectors (what UEFI firmware reads on USB
#      sticks), \EFI\BOOT\BOOTX64.EFI = systemd-boot, \EFI\Linux\ = the UKI,
#      nothing else (no loader.conf: systemd-boot starts the one UKI)
#   3. the dm-verity hash tree and the root partition, byte for byte
# No root needed for an image file; a device needs root, like any write to it.

# start and size (512-byte sectors) of a partition of layout.sfdisk by type
stick_part() { # LAYOUT TYPE-GUID
	awk -F'[=,]' -v t="$2" 'toupper($0) ~ "TYPE=" t { gsub(/ /, ""); print $2, $4; exit }' "$1"
}
STICK_ESP=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
STICK_ROOT=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
STICK_VERITY=2C7357ED-EBD2-46D9-AEC1-23D437EC2BF5

stick_bytes() { # SRC
	local last
	last=$(sed -n 's/^last-lba: *//p' "$1/layout.sfdisk")
	[[ $last =~ ^[0-9]+$ ]] || die "$1/layout.sfdisk has no last-lba"
	# last usable LBA + the backup GPT (33 sectors) + 1
	echo $(((last + 34) * 512))
}

stick_write() { # TARGET SRC [ROOT]
	local target=$1 src=$2 rootsrc=${3:-$2/root.img} layout=$2/layout.sfdisk esp root verity f
	for f in layout.sfdisk systemd-boot.efi boot.efi root.verity; do
		[[ -f $src/$f ]] || die "$src/$f missing (not a usb build or release)"
	done
	[[ $rootsrc == - || -f $rootsrc ]] || die "$rootsrc missing"
	esp=$(stick_part "$layout" "$STICK_ESP")
	root=$(stick_part "$layout" "$STICK_ROOT")
	verity=$(stick_part "$layout" "$STICK_VERITY")
	[[ -n $esp && -n $root && -n $verity ]] || die "$layout: not the ESP + root + root-verity layout"
	(($(stat -c %s "$src/root.verity") <= ${verity#* } * 512)) || die "root.verity does not fit its partition"
	[[ $rootsrc == - ]] || (($(stat -c %s "$rootsrc") <= ${root#* } * 512)) || die "root.img does not fit its partition"

	local dd=(dd bs=4M status=none conv=notrunc oflag=seek_bytes)
	if [[ -b $target ]]; then
		dd=(dd bs=4M status=progress conv=notrunc,fsync oflag=seek_bytes)
	else
		rm -f "$target"
		truncate -s "$(stick_bytes "$src")" "$target"
	fi
	# 1. partition table: without last-lba, so sfdisk uses the whole device
	# and puts the backup GPT at its end.
	sed '/^last-lba:/d' "$layout" | sfdisk --quiet --no-reread --wipe always "$target" ||
		die "sfdisk could not write the partition table"
	# 2. ESP
	set -- $esp
	local out
	out=$(mkfs.fat -F 32 -S 512 -n ESP -I --offset="$1" "$target" $(($2 / 2)) 2>&1) ||
		die "mkfs.fat failed: $out"
	local m=$target@@$(($1 * 512))
	mmd -i "$m" ::/EFI ::/EFI/BOOT ::/EFI/Linux &&
		mcopy -i "$m" "$src/systemd-boot.efi" ::/EFI/BOOT/BOOTX64.EFI &&
		mcopy -i "$m" "$src/boot.efi" ::/EFI/Linux/safespace-arch-usb.efi || die "copying onto the ESP failed"
	# 3. hash tree, then the root partition
	set -- $verity
	"${dd[@]}" if="$src/root.verity" of="$target" seek=$(($1 * 512)) || die "writing root.verity failed"
	set -- $root
	if [[ $rootsrc == - ]]; then
		"${dd[@]}" iflag=fullblock of="$target" seek=$(($1 * 512)) || die "writing the root partition failed"
	else
		"${dd[@]}" if="$rootsrc" of="$target" seek=$(($1 * 512)) || die "writing root.img failed"
	fi
	sync
}
