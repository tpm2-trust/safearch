#!/usr/bin/env bash
# Write a "usb" image to a USB stick / SD card: built here (mkosi.output/usb/), or
# a usb release from a distribution server (share path or URL).
# Images of the "network" variant have no ESP and are not written to a medium;
# they are released with release.sh (see README.md, "Releasing").
#
# Needs no Secure Boot keys and no package cache: the image is already signed.
# Takes raw (.raw) or zstd-compressed (.raw.zst) images. Only blocks that
# contain data are written. Nothing is grown: the stick is read-only at
# runtime, so the rest of it simply stays unused.
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

usage() {
	cat <<EOF
Usage: sudo $0 [IMAGE] DEVICE [--yes]

  IMAGE      .raw or .raw.zst to write (default: the newest usb build in mkosi.output/usb/),
             or a usb release on a distribution server: a local share path
             (/srv/safespace/share/usb/image.raw.zst) or its URL
             (http://<server>/safespace/usb/), checked against its SHA256SUMS
  DEVICE     whole target disk, e.g. /dev/sdb or /dev/mmcblk0
  --yes      do not ask for confirmation
EOF
}

log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }

CONFIRM=1
ARGS=()
while (($#)); do
	case $1 in
		--yes) CONFIRM=0; shift ;;
		-h|--help) usage; exit 0 ;;
		-*) usage >&2; exit 1 ;;
		*) ARGS+=("$1"); shift ;;
	esac
done
case ${#ARGS[@]} in
	1)
		pick=(! -name '*-network_*')
		IMAGE=$(find "$HERE/mkosi.output/usb" -mindepth 2 -maxdepth 2 -type f \( -name '*.raw.zst' -o -name '*.raw' \) \
			"${pick[@]}" -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR == 1 { print $2 }' || true)
		DEVICE=${ARGS[0]}
		;;
	2) IMAGE=${ARGS[0]}; DEVICE=${ARGS[1]} ;;
	*) usage >&2; exit 1 ;;
esac

[[ $EUID -eq 0 ]] || die "must run as root"

# A usb release from a distribution server: download it next to its SHA256SUMS.
# Authenticity is checked on the written medium: sudo ./diagnose.sh --db-cert ...
if [[ $IMAGE =~ ^https?:// ]]; then
	command -v curl >/dev/null || die "missing 'curl'"
	[[ $IMAGE == */ ]] && IMAGE+=image.raw.zst
	DL=$(mktemp -d /var/tmp/safespace-burn.XXXXXX)
	trap 'rm -rf "$DL"' EXIT
	log "Downloading $IMAGE"
	curl -fL --progress-bar -o "$DL/image.raw.zst" "$IMAGE" || die "download failed"
	curl -fsS -o "$DL/SHA256SUMS" "${IMAGE%/*}/SHA256SUMS" || die "no SHA256SUMS next to $IMAGE"
	(cd "$DL" && grep ' \*\?image\.raw\.zst$' SHA256SUMS | sha256sum --quiet --strict -c) || die "download does not match SHA256SUMS"
	IMAGE=$DL/image.raw.zst
fi
for cmd in sfdisk partx wipefs blockdev lsblk blkid dd zstd; do
	command -v "$cmd" >/dev/null || die "missing '$cmd'"
done

# --- checks --------------------------------------------------------------------

hint="sudo ./build.sh usb"
[[ -n $IMAGE && -e $IMAGE ]] || die "image ${IMAGE:-in mkosi.output/} not found (run: $hint)"
IMAGE=$(readlink -f "$IMAGE")
[[ $(basename "$IMAGE") == *-network_* ]] &&
	die "$(basename "$IMAGE") is a network build (no ESP, nothing to boot from a medium): release it with ./release.sh network, see README.md"
if [[ $IMAGE == *.zst ]]; then
	COMPRESSED=1
	# mkosi compresses as a stream, so the zstd header has no content size.
	# Take it from the primary GPT header instead (LBA 1, 512-byte sectors):
	# offset 32 holds the LBA of the backup header, the image's last sector.
	# zstd is cut off by head on purpose, so pipefail must not count that.
	hdr=$(set +o pipefail; zstd -dc "$IMAGE" 2>/dev/null | head -c 1024 | tail -c 512 | od -An -v -tx1 | tr -d ' \n' || true)
	[[ ${hdr:0:16} == 4546492050415254 ]] || die "$IMAGE does not contain a GPT disk image (512-byte sectors)"
	le=${hdr:64:16}
	backup_lba=$((16#${le:14:2}${le:12:2}${le:10:2}${le:8:2}${le:6:2}${le:4:2}${le:2:2}${le:0:2}))
	IMAGE_BYTES=$(((backup_lba + 1) * 512))
	log "Checking $IMAGE for corruption"
	zstd -tq "$IMAGE" || die "$IMAGE is damaged (zstd -t failed)"
else
	COMPRESSED=0
	IMAGE_BYTES=$(stat -c %s "$IMAGE")
	[[ -z $(losetup -j "$IMAGE") ]] || die "$IMAGE is attached to a loop device (build still running?)"
	sfdisk -d "$IMAGE" 2>/dev/null | grep -q '^label: gpt' || die "$IMAGE has no GPT partition table"
fi

[[ -b $DEVICE ]] || die "$DEVICE is not a block device"
[[ $(lsblk -dno TYPE "$DEVICE") == disk ]] || die "$DEVICE is not a whole disk"
if lsblk -nro MOUNTPOINTS "$DEVICE" | grep -q .; then
	lsblk -o NAME,MOUNTPOINTS "$DEVICE" >&2
	die "$DEVICE has mounted partitions"
fi
if lsblk -nro TYPE "$DEVICE" | grep -qvE '^(disk|part)$'; then
	die "$DEVICE is in use (LUKS, LVM or RAID on top of it)"
fi
DEVICE_BYTES=$(blockdev --getsize64 "$DEVICE")
((DEVICE_BYTES >= IMAGE_BYTES)) ||
	die "$DEVICE ($((DEVICE_BYTES >> 20)) MiB) is smaller than the image ($((IMAGE_BYTES >> 20)) MiB)"

log "Image:  $IMAGE ($((IMAGE_BYTES >> 20)) MiB, $(du -m "$IMAGE" | cut -f1) MiB on disk)"
MANIFEST=${IMAGE%.raw*}.manifest
[[ -f $MANIFEST ]] && log "        $(grep -c '"name"' "$MANIFEST") packages (manifest), built $(date -r "$IMAGE" '+%F %R')"
log "Target: $DEVICE"
lsblk -o NAME,SIZE,MODEL,TRAN,RM "$DEVICE"
if ((CONFIRM)); then
	read -rp "ALL DATA on $DEVICE will be destroyed. Type YES to continue: " answer
	[[ $answer == YES ]] || die "aborted"
fi

partitions() {
	lsblk -lnpo NAME,TYPE "$DEVICE" | awk '$2 == "part" { print $1 }'
}

# --- write ---------------------------------------------------------------------

# Zero blocks of the image are skipped (conv=sparse), so whatever was on the
# device stays there. Remove every old filesystem/RAID/LUKS signature first, so
# nothing stale can be detected in the gaps later.
log "Wiping old signatures on $DEVICE"
while read -r part; do
	wipefs -aq "$part"
done < <(partitions)
wipefs -aq "$DEVICE"

log "Writing image (only blocks with data)"
if ((COMPRESSED)); then
	# fullblock: zero detection needs whole 4 MiB blocks, pipes deliver less.
	zstd -dc "$IMAGE" | dd of="$DEVICE" bs=4M iflag=fullblock conv=sparse,fsync oflag=direct status=progress
else
	dd if="$IMAGE" of="$DEVICE" bs=4M conv=sparse,fsync oflag=direct status=progress
fi

# The image's backup GPT sits at the image's end, not at the device's end.
# Move it, otherwise firmware and tools report a damaged partition table.
log "Relocating backup GPT to the end of $DEVICE"
sfdisk --quiet --relocate gpt-bak-std "$DEVICE"

blockdev --rereadpt "$DEVICE"
udevadm settle

NPARTS=$(partx -g -o NR "$DEVICE" | wc -l)
for _ in {1..10}; do
	mapfile -t PARTS < <(partitions)
	((${#PARTS[@]} == NPARTS)) && break
	sleep 1
done
# ESP, root, root-verity.
((NPARTS >= 1 && ${#PARTS[@]} == NPARTS)) || die "partitions on $DEVICE did not show up after writing"

# --- finish --------------------------------------------------------------------

sync
blockdev --flushbufs "$DEVICE"
if lsblk -nro MOUNTPOINTS "$DEVICE" | grep -q .; then
	lsblk -o NAME,MOUNTPOINTS "$DEVICE" >&2
	die "$DEVICE still has mounted partitions, do not unplug it"
fi
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$DEVICE"
log "Done. $DEVICE can be unplugged."
