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
release_get() { sed -n "s/^$2=//p" "$1" | head -1; }
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
ROOT_URL="" ROOT_SUM=""
if [[ $SOURCE =~ ^https?:// ]]; then
	command -v curl >/dev/null || die "missing 'curl'"
	base=${SOURCE%/}
	log "Fetching the release from $base/"
	for f in SHA256SUMS release roothash layout.sfdisk systemd-boot.efi boot.efi root.verity; do
		curl -fsS -o "$TMP/$f" "$base/$f" || die "cannot fetch $base/$f (not a safespace release?)"
	done
	(cd "$TMP" && grep -E ' \*?(release|roothash|layout\.sfdisk|systemd-boot\.efi|boot\.efi|root\.verity)$' SHA256SUMS |
		sha256sum --quiet --strict -c) || die "the release's files do not match its SHA256SUMS"
	ROOT_URL=$base/root.img
	ROOT_SUM=$(awk '$2 == "root.img" || $2 == "*root.img" { print $1 }' "$TMP/SHA256SUMS")
	[[ $ROOT_SUM =~ ^[0-9a-f]{64}$ ]] || die "no root.img in SHA256SUMS"
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
[[ -f $SRC/layout.sfdisk ]] || die "$SRC has no layout.sfdisk: not a build or release (or one from before the single build)"
if [[ -z $ROOT_URL && -f $SRC/SHA256SUMS ]]; then
	log "Checking $SRC against its SHA256SUMS"
	(cd "$SRC" && sha256sum --quiet --strict -c SHA256SUMS) || die "$SRC does not match its SHA256SUMS"
fi
if [[ -f $SRC/build.json ]]; then
	what="build $(builds_info "$SRC" build), groups $(builds_info "$SRC" groups), built $(builds_info "$SRC" finished)"
elif [[ -f $SRC/release ]]; then
	what="release $(release_get "$SRC/release" BUILD), groups $(release_get "$SRC/release" GROUPS), built $(release_get "$SRC/release" BUILT)"
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

log "Writing the partition table, the ESP, root.verity and root.img"
if [[ -n $ROOT_URL ]]; then
	# The root partition goes from the server onto the stick in one stream;
	# its checksum is taken on the way (fifo -> sha256sum) and compared after.
	mkfifo "$TMP/root.fifo"
	sha256sum <"$TMP/root.fifo" | cut -d' ' -f1 >"$TMP/root.sha" &
	sum_pid=$!
	ok=1
	curl -fsS "$ROOT_URL" | tee "$TMP/root.fifo" | stick_write "$TARGET" "$SRC" - || ok=0
	wait "$sum_pid" || true
	if ((!ok)) || [[ $(cat "$TMP/root.sha" 2>/dev/null) != "$ROOT_SUM" ]]; then
		if [[ -b $TARGET ]]; then wipefs -aq "$TARGET"; else rm -f "$TARGET"; fi
		die "the download of root.img failed or does not match SHA256SUMS: $TARGET $([[ -b $TARGET ]] && echo 'was wiped again' || echo 'was removed')"
	fi
else
	stick_write "$TARGET" "$SRC"
fi

if [[ -b $TARGET ]]; then
	blockdev --rereadpt "$TARGET"
	udevadm settle
	for _ in {1..10}; do
		(($(lsblk -lnpo TYPE "$TARGET" | grep -c part) == 3)) && break
		sleep 1
	done
	(($(lsblk -lnpo TYPE "$TARGET" | grep -c part) == 3)) || die "the partitions on $TARGET did not show up after writing"
	blockdev --flushbufs "$TARGET"
	lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$TARGET"
	log "Done. $TARGET can be unplugged (check it with: sudo ./diagnose.sh $TARGET)."
else
	log "Done: $TARGET ($((BYTES >> 20)) MiB)"
fi
