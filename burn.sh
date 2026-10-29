#!/usr/bin/env bash
# Write a build onto a USB stick / SD card, assembled from its parts
# (lib/stick.sh): the partition table the build recorded, an ESP with the
# signed systemd-boot and UKI, the dm-verity hash tree and the root partition.
# Needs no keys and no build: the parts are signed already.
#
#   sudo ./burn.sh [SOURCE] DEVICE [--yes]
#   ./burn.sh [SOURCE] --image FILE        a stick image file instead (no root)
#
#   SOURCE  where the parts come from (default: the newest build here):
#           - a build, as ./build.sh list shows it (base-remotedesktop_20261019-0930)
#           - a directory with the parts: a build directory, mkosi.release,
#             or a distribution server's share (/srv/safespace/share)
#           - a distribution server's URL, e.g. http://10.0.0.1/safespace/:
#             the root partition is streamed straight onto the stick, and
#             every file is checked against the release's SHA256SUMS
#   DEVICE  the whole stick, e.g. /dev/sdb or /dev/mmcblk0
#   --yes   do not ask before overwriting DEVICE
#
# The same build boots over the network (release.sh). Check a written stick
# with diagnose.sh (signatures against db.pem, root block by block).
set -Eeuo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; }
# shellcheck source=lib/verify.sh
source "$HERE/lib/verify.sh"
# shellcheck source=lib/stick.sh
source "$HERE/lib/stick.sh"
# shellcheck source=lib/builds.sh
source "$HERE/lib/builds.sh"

CONFIRM=1 IMAGE_OUT="" ARGS=()
while (($#)); do
	case $1 in
		--yes) CONFIRM=0; shift ;;
		--image) IMAGE_OUT=${2:?--image needs a file}; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		-*) usage >&2; exit 1 ;;
		*) ARGS+=("$1"); shift ;;
	esac
done
if [[ -n $IMAGE_OUT ]]; then
	((${#ARGS[@]} <= 1)) || { usage >&2; exit 1; }
	SOURCE=${ARGS[0]:-} DEVICE=""
else
	case ${#ARGS[@]} in
		1) SOURCE="" DEVICE=${ARGS[0]} ;;
		2) SOURCE=${ARGS[0]} DEVICE=${ARGS[1]} ;;
		*) usage >&2; exit 1 ;;
	esac
	[[ $EUID -eq 0 ]] || die "writing a device needs root (or --image FILE)"
fi
for cmd in sfdisk mkfs.fat mmd mcopy dd sha256sum; do
	command -v "$cmd" >/dev/null || die "missing '$cmd' (pacman -S util-linux dosfstools mtools coreutils)"
done

# --- where the parts come from ---------------------------------------------------

TMP=$(mktemp -d -t safespace-burn.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
BASE_URL=""
if [[ $SOURCE =~ ^https?:// ]]; then
	command -v curl >/dev/null || die "missing 'curl'"
	BASE_URL=${SOURCE%/}
	log "Fetching the release from $BASE_URL/"
	for f in SHA256SUMS release layout.sfdisk systemd-boot.efi boot.efi; do
		curl -fsS -o "$TMP/$f" "$BASE_URL/$f" || die "cannot fetch $BASE_URL/$f (not a safespace release?)"
	done
	(cd "$TMP" && grep -E ' \*?(release|layout\.sfdisk|systemd-boot\.efi|boot\.efi)$' SHA256SUMS |
		sha256sum --quiet --strict -c) || die "the release's files do not match its SHA256SUMS"
	SRC=$TMP
elif [[ -d $SOURCE ]]; then
	SRC=$(readlink -f "$SOURCE")
elif [[ -n $SOURCE ]]; then
	SRC=$(builds_dir "$(builds_find "$SOURCE")")
else
	b=$(builds_newest)
	[[ -n $b ]] || die "no build here (sudo ./build.sh, or give a SOURCE)"
	SRC=$(builds_dir "$b")
fi
[[ -f $SRC/layout.sfdisk ]] || die "$SRC has no layout.sfdisk: not a build or release"
if [[ -z $BASE_URL && -f $SRC/SHA256SUMS ]]; then
	log "Checking $SRC against its SHA256SUMS"
	(cd "$SRC" && sha256sum --quiet --strict -c SHA256SUMS) || die "$SRC does not match its SHA256SUMS"
fi
if [[ -f $SRC/build.json ]]; then
	what="build $(builds_info "$SRC" build), combinations $(builds_combo_names "$SRC"), built $(builds_info "$SRC" finished)"
elif [[ -f $SRC/release ]]; then
	what="release $(release_get "$SRC/release" BUILD), combinations $(release_get "$SRC/release" COMBINATIONS), built $(release_get "$SRC/release" BUILT)"
else
	what=$SRC
fi
BYTES=$(stick_bytes "$SRC")
log "Source: $what"
log "        ${SOURCE:-$SRC} ($((BYTES >> 20)) MiB on the stick)"

# --- target ------------------------------------------------------------------------

if [[ -n $IMAGE_OUT ]]; then
	TARGET=$IMAGE_OUT
	[[ ! -b $TARGET ]] || die "--image is for files; for a device give it as DEVICE"
else
	TARGET=$DEVICE
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
	((DEVICE_BYTES >= BYTES)) || die "$DEVICE ($((DEVICE_BYTES >> 20)) MiB) is smaller than the stick needs ($((BYTES >> 20)) MiB)"
	log "Target: $DEVICE"
	lsblk -o NAME,SIZE,MODEL,TRAN,RM "$DEVICE"
	if ((CONFIRM)); then
		read -rp "ALL DATA on $DEVICE will be destroyed. Type YES to continue: " answer
		[[ $answer == YES ]] || die "aborted"
	fi
	# Remove every old filesystem/RAID/LUKS signature, so nothing stale can be
	# detected in the parts of the stick that are not written.
	log "Wiping old signatures on $DEVICE"
	lsblk -lnpo NAME,TYPE "$DEVICE" | awk '$2 == "part" { print $1 }' | while read -r p; do wipefs -aq "$p"; done
	wipefs -aq "$DEVICE"
fi

# --- write -------------------------------------------------------------------------

log "Writing the partition table, the ESP, the hash trees and the root partitions"
# From a server, the root and hash tree files go onto the stick in one stream
# each; their checksums are taken on the way (fifo -> sha256sum) and compared
# with SHA256SUMS afterwards.
fetch_url() { # FILE
	local rc
	mkfifo "$TMP/$1.fifo"
	sha256sum <"$TMP/$1.fifo" | cut -d' ' -f1 >"$TMP/$1.sha" &
	curl -fsS "$BASE_URL/$1" | tee "$TMP/$1.fifo"
	rc=$?
	wait $!
	return $rc
}
bad=""
if [[ -n $BASE_URL ]]; then
	(stick_write "$TARGET" "$SRC" fetch_url) || bad="the download or the write failed"
	if [[ -z $bad ]]; then
		while read -r f _; do
			want=$(awk -v f="$f" '$2 == f || $2 == "*" f { print $1 }' "$TMP/SHA256SUMS")
			[[ -n $want && $(cat "$TMP/$f.sha" 2>/dev/null) == "$want" ]] || { bad="$f does not match SHA256SUMS"; break; }
		done < <(stick_files "$SRC")
	fi
else
	(stick_write "$TARGET" "$SRC") || bad="the write failed"
fi
if [[ -n $bad ]]; then
	if [[ -b $TARGET ]]; then wipefs -aq "$TARGET"; else rm -f "$TARGET"; fi
	die "$bad: $TARGET $([[ -b $TARGET ]] && echo 'was wiped again' || echo 'was removed')"
fi

if [[ -b $TARGET ]]; then
	blockdev --rereadpt "$TARGET"
	udevadm settle
	nparts=$((1 + $(stick_files "$SRC" | wc -l)))
	for _ in {1..10}; do
		(($(lsblk -lnpo TYPE "$TARGET" | grep -c part) == nparts)) && break
		sleep 1
	done
	(($(lsblk -lnpo TYPE "$TARGET" | grep -c part) == nparts)) || die "the partitions on $TARGET did not show up after writing"
	blockdev --flushbufs "$TARGET"
	lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$TARGET"
	log "Done. $TARGET can be unplugged (check it with: sudo ./diagnose.sh $TARGET)."
else
	log "Done: $TARGET ($((BYTES >> 20)) MiB)"
fi
