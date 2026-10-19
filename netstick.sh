#!/usr/bin/env bash
# Build a "netstick": a small USB stick image that boots a published network
# build on machines whose firmware cannot start an EFI image that came over
# the network (see NETBOOT.md, "Machines that cannot start a network-loaded
# image"). The stick holds only the loader; the root image still comes from
# the netboot server.
#
#   sudo ./netstick.sh [--tree DIR] [--version VER] [--output FILE]
#   sudo dd if=mkosi.output/safespace-arch-netstick_<VER>.raw of=/dev/sdX \
#        bs=4M conv=fsync oflag=direct status=progress
#   (or: sudo ./burn.sh --netstick /dev/sdX)
#
#   --tree DIR     netboot tree the version was published into with
#                  release.sh (default: mkosi.release/network/, or a
#                  distribution server's share/network/)
#   --version VER  version directory in the tree (default: what "current"
#                  points at)
#   --output FILE  image to write (default:
#                  mkosi.output/safespace-arch-netstick_<VER>.raw)
#
# Stick layout (GPT, one partition): an ESP with FAT32 and 512-byte sectors,
#   \EFI\BOOT\BOOTX64.EFI                       systemd-boot, signed here
#   \EFI\Linux\safespace-arch-network_<VER>.efi the published UKI, unchanged
# No loader.conf: systemd-boot starts the only UKI right away, writes nothing.
# Same loader path as the usb variant, which such firmware does boot.
#
# Only published versions are accepted: the UKI's netroot URL points at
# <base>/<VER>/, so the stick boots only while the server serves that
# version. The UKI is taken from the tree, i.e. after release.sh has
# verified it against its root image. A new release needs a new stick.
#
# Needs root: systemd-boot is signed with the Secure Boot db key that mkosi
# uses (SecureBootKey=/SecureBootCertificate= incl. mkosi.local.conf).
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; }
# shellcheck source=lib/uefi.sh
source "$HERE/lib/uefi.sh"

TREE=$HERE/mkosi.release/network
VERSION="" OUTPUT=""
while (($#)); do
	case $1 in
		--tree) TREE=${2:?--tree needs a directory}; shift 2 ;;
		--version) VERSION=${2:?--version needs a build version}; shift 2 ;;
		--output) OUTPUT=${2:?--output needs a file name}; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die "unknown option $1" ;;
	esac
done

[[ $EUID -eq 0 ]] || die "must run as root (systemd-boot is signed with the root-only db key)"
for cmd in mkosi python3 openssl objcopy sfdisk mkfs.fat mcopy mmd; do
	command -v "$cmd" >/dev/null || die "missing '$cmd'"
done
SDBOOT=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
[[ -f $SDBOOT ]] || die "$SDBOOT missing (systemd)"

# --- the published build -------------------------------------------------------

[[ -d $TREE ]] || die "no netboot tree $TREE (release first: ./release.sh network)"
if [[ -z $VERSION ]]; then
	VERSION=$(readlink "$TREE/current" 2>/dev/null) || die "$TREE/current missing: pass --version"
fi
[[ $VERSION =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid version '$VERSION'"
DIR=$TREE/$VERSION
UKI=$DIR/boot.efi
for f in boot.efi roothash root.img root.verity; do
	[[ -f $DIR/$f ]] || die "$DIR/$f missing: not a release written by release.sh"
done

CMDLINE=$(uefi_section "$UKI" .cmdline)
ROOTHASH=$(tr -d '[:space:]' <"$DIR/roothash")
[[ " $CMDLINE " == *" roothash=$ROOTHASH "* ]] ||
	die "the UKI's roothash does not match $DIR/roothash"
mapfile -t URLS < <(tr ' ' '\n' <<<"$CMDLINE" | sed -n 's/^safespace\.netroot=//p')
((${#URLS[@]})) || die "no safespace.netroot= in the UKI: not a network build"
for url in "${URLS[@]}"; do
	[[ $(basename "${url%/}") == "$VERSION" ]] ||
		die "the UKI loads its root from $url, not from .../$VERSION/"
done

UKI_FP=$(uefi_fingerprint "$UKI" 2>/dev/null) || die "the UKI is not signed"
log "Build:    safespace-arch-network_$VERSION (published in $TREE)"
log "netroot:  ${URLS[*]}"
log "UKI:      $(($(stat -c %s "$UKI") >> 20)) MiB, $UKI_FP"

# --- sign systemd-boot with mkosi's key ----------------------------------------

mapfile -t SIGN < <(cd "$HERE" && mkosi --profile=network --json summary | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
i = d["Images"][-1] if "Images" in d else d
for k in ("SecureBootKey", "SecureBootCertificate", "SecureBootSignTool"):
    print(i.get(k) or "")
')
KEY=${SIGN[0]:-} CERT=${SIGN[1]:-} TOOL=${SIGN[2]:-}
[[ -f $KEY && -f $CERT ]] || die "Secure Boot key/certificate from mkosi not found: '$KEY' '$CERT'"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
case $TOOL in
	systemd-sbsign | auto | "")
		sign=(/usr/lib/systemd/systemd-sbsign sign --private-key="$KEY" --certificate="$CERT"
			--output="$W/BOOTX64.EFI" "$SDBOOT") ;;
	sbsign)
		sign=(sbsign --key "$KEY" --cert "$CERT" --output "$W/BOOTX64.EFI" "$SDBOOT") ;;
	*) die "unsupported SecureBootSignTool=$TOOL" ;;
esac
out=$("${sign[@]}" 2>&1) || die "signing systemd-boot failed: $out"
BOOT_FP=$(uefi_fingerprint "$W/BOOTX64.EFI" 2>/dev/null) || die "signing systemd-boot failed"
[[ $BOOT_FP == "$UKI_FP" ]] ||
	die "systemd-boot ($BOOT_FP) and the UKI ($UKI_FP) are signed by different keys"
log "systemd-boot signed with $CERT"

# --- the image -----------------------------------------------------------------

OUTPUT=${OUTPUT:-$HERE/mkosi.output/safespace-arch-netstick_$VERSION.raw}
mkdir -p "$(dirname "$OUTPUT")"
# ESP: content plus a quarter as headroom, at least 64 MiB (FAT32 needs > 32 MiB).
content=$((($(stat -c %s "$UKI") + $(stat -c %s "$W/BOOTX64.EFI")) >> 20))
esp_mib=$((content + content / 4 + 16))
((esp_mib >= 64)) || esp_mib=64

log "Writing $OUTPUT (ESP $esp_mib MiB)"
# FAT32 with 512-byte sectors, like the usb variant's ESP: many firmwares do
# not read 4K-sector FAT on USB sticks.
FAT=$W/esp.img
truncate -s ${esp_mib}M "$FAT"
mkfs.fat -F 32 -S 512 -n SAFESPACE "$FAT" >/dev/null
mmd -i "$FAT" ::/EFI ::/EFI/BOOT ::/EFI/Linux
mcopy -i "$FAT" "$W/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$FAT" "$UKI" "::/EFI/Linux/safespace-arch-network_$VERSION.efi"
# GPT: 1 MiB in front (table, alignment), the ESP, 1 MiB behind (backup table).
rm -f "$OUTPUT"
truncate -s $((esp_mib + 2))M "$OUTPUT"
printf 'label: gpt\nstart=2048, size=%d, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"\n' \
	$((esp_mib * 2048)) | sfdisk -q "$OUTPUT"
dd if="$FAT" of="$OUTPUT" bs=1M seek=1 conv=notrunc,sparse status=none

log "Done. Write it to a stick (ALL DATA on it is lost):"
echo "  sudo dd if=$OUTPUT of=/dev/sdX bs=4M conv=fsync oflag=direct status=progress"
echo "  (or: sudo ./burn.sh --netstick /dev/sdX; check it with: sudo ./diagnose.sh /dev/sdX)"
log "The stick boots only while the server serves ${URLS[0]}"
