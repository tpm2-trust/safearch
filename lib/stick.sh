# Assemble a usb stick from a build's (or release's) parts. Sourced by burn.sh
# and test-vm.sh, and by tests/run.sh. Expects die() and log().
#
#   stick_bytes SRC                 size of the stick image (from layout.sfdisk)
#   stick_files SRC                 "<file> <start> <size>" per root/verity partition
#   stick_write TARGET SRC [FETCH]  write the stick to TARGET (a block device, or
#                                   an image file, created if missing)
#
# SRC is a directory with layout.sfdisk, systemd-boot.efi, boot.efi and the
# root/verity files the layout names: root-<name>.img and root-<name>.verity
# per combination (the partitions are named root-<name> and
# root-<name>-verity). FETCH is a command that prints a file's content
# (FETCH root-<name>.img), so burn.sh can stream
# the large files from a server; without it they are read from SRC. Each is
# written into its partition and never beyond it.
#
# What it writes is what systemd-repart laid out in the build:
#   1. the partition table from layout.sfdisk (types, UUIDs derived from the
#      root hashes, sizes, attributes)
#   2. the ESP: FAT32 with 512-byte sectors (what UEFI firmware reads on USB
#      sticks), \EFI\BOOT\BOOTX64.EFI = systemd-boot, \EFI\Linux\ = the UKI,
#      nothing else (no loader.conf: systemd-boot starts the one UKI)
#   3. the dm-verity hash trees and the root partitions, byte for byte
# No root needed for an image file; a device needs root, like any write to it.

# The partition table's helpers (layout_part, GPT_ESP).
# shellcheck source=lib/verify.sh
source "${BASH_SOURCE[0]%/*}/verify.sh"

stick_bytes() { # SRC
	local last
	last=$(sed -n 's/^last-lba: *//p' "$1/layout.sfdisk")
	[[ $last =~ ^[0-9]+$ ]] || die "$1/layout.sfdisk has no last-lba"
	# last usable LBA + the backup GPT (33 sectors) + 1
	echo $(((last + 34) * 512))
}

# The data partitions and their files, by partition name.
stick_files() { # SRC
	awk -F', *' '/name="root-/ {
		start = size = name = ""
		for (i = 1; i <= NF; i++) {
			split($i, kv, "="); k = kv[1]; v = kv[2]; gsub(/[ "]/, "", k); gsub(/[ "]/, "", v)
			if (k ~ /start$/) start = v; else if (k == "size") size = v; else if (k == "name") name = v
		}
		if (name ~ /-verity$/) { sub(/-verity$/, "", name); f = name ".verity" }
		else f = name ".img"
		print f, start, size
	}' "$1/layout.sfdisk"
}

stick_write() { # TARGET SRC [FETCH]
	local target=$1 src=$2 fetch=${3:-} layout=$2/layout.sfdisk esp f start size files
	for f in layout.sfdisk systemd-boot.efi boot.efi; do
		[[ -f $src/$f ]] || die "$src/$f missing (not a build or release)"
	done
	esp="$(layout_part "$layout" "$GPT_ESP" start) $(layout_part "$layout" "$GPT_ESP" size)"
	[[ $esp != " " ]] || die "$layout: no ESP"
	files=$(stick_files "$src")
	[[ -n $files ]] || die "$layout: no root partitions"
	while read -r f start size; do
		[[ $f =~ ^root-[a-z][a-z0-9-]*\.(img|verity)$ && $start =~ ^[0-9]+$ && $size =~ ^[0-9]+$ ]] ||
			die "$layout: unexpected partition $f"
		[[ -n $fetch ]] && continue
		[[ -f $src/$f ]] || die "$src/$f missing"
		(($(stat -c %s "$src/$f") <= size * 512)) || die "$f does not fit its partition"
	done <<<"$files"

	local dd=(dd bs=4M status=none conv=notrunc oflag=seek_bytes iflag=fullblock,count_bytes)
	if [[ -b $target ]]; then
		dd=(dd bs=4M status=progress conv=notrunc,fsync oflag=seek_bytes iflag=fullblock,count_bytes)
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
		mcopy -i "$m" "$src/boot.efi" ::/EFI/Linux/safespace-arch.efi || die "copying onto the ESP failed"
	# 3. hash trees and root partitions, each at most its partition's size
	while read -r f start size; do
		if [[ -n $fetch ]]; then
			"$fetch" "$f" | "${dd[@]}" of="$target" seek=$((start * 512)) count=$((size * 512)) || die "writing $f failed"
		else
			"${dd[@]}" if="$src/$f" of="$target" seek=$((start * 512)) count=$((size * 512)) || die "writing $f failed"
		fi
	done <<<"$files"
	sync
}
