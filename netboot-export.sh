#!/usr/bin/env bash
# Publish a "network" build so that machines can boot it over the network:
# verify the artifacts, put them into <tree>/<version>/ and point
# <tree>/current at that directory. See NETBOOT.md for the server itself.
#
#   ./netboot-export.sh [OPTIONS]
#
#   --tree DIR        where to write (default: mkosi.netboot/). On the build
#                     host this is a staging tree you then copy to the server;
#                     with --rsync it is copied for you.
#   --version VER     publish this build (default: the newest network build in
#                     mkosi.output/), e.g. --version 20261016-1830
#   --rsync TARGET    also rsync the new version and the "current" symlink to
#                     TARGET, e.g. root@boot:/srv/netboot/safespace
#   --no-current      do not move the "current" symlink (stage only)
#   --prune N         delete all but the newest N versions in the tree
#                     afterwards (never the one "current" points at)
#   --yes             do not ask before deleting pruned versions
#
# Published per version (what the firmware and the initrd ask for):
#   <tree>/<version>/boot.efi      signed UKI: firmware boot file
#   <tree>/<version>/root.img      erofs root partition (dm-verity data)
#   <tree>/<version>/root.verity   its dm-verity hash tree
#   <tree>/<version>/roothash      the root hash, for reference
#   <tree>/<version>/cmdline       the signed kernel command line, for reference
#   <tree>/current -> <version>    what the DHCP/HTTP boot URL points at
#
# The version directory name is taken from the safespace.netroot= URL inside
# the signed UKI, because that is where the initrd will look for root.img.
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m==> WARNING:\e[0m %s\n' "$*" >&2; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; }
# shellcheck source=lib/uefi.sh
source "$HERE/lib/uefi.sh"

TREE=$HERE/mkosi.netboot
VERSION="" RSYNC="" CURRENT=1 PRUNE=0 CONFIRM=1
while (($#)); do
	case $1 in
		--tree) TREE=${2:?--tree needs a directory}; shift 2 ;;
		--version) VERSION=${2:?--version needs a build version}; shift 2 ;;
		--rsync) RSYNC=${2:?--rsync needs a target}; shift 2 ;;
		--no-current) CURRENT=0; shift ;;
		--prune) PRUNE=${2:?--prune needs a number}; shift 2 ;;
		--yes) CONFIRM=0; shift ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die "unknown option $1" ;;
	esac
done
for cmd in zstd veritysetup openssl python3; do
	command -v "$cmd" >/dev/null || die "missing '$cmd'"
done

OUT=$HERE/mkosi.output
ID=safespace-arch-network

# --- pick the build ------------------------------------------------------------

if [[ -z $VERSION ]]; then
	newest=$(find "$OUT" -maxdepth 1 -name "${ID}_*.efi" -printf '%T@ %p\n' 2>/dev/null |
		sort -nr | awk 'NR == 1 { print $2 }')
	[[ -n $newest ]] || die "no network build in mkosi.output/ (run: sudo ./build.sh network)"
	VERSION=$(basename "$newest" .efi); VERSION=${VERSION#"${ID}_"}
fi
BASE=$OUT/${ID}_$VERSION
UKI=$BASE.efi
ROOTHASH_FILE=$BASE.roothash
# mkosi compresses the split partitions (CompressOutput=zstd); accept both.
pick() { # suffix
	for f in "$BASE.$1.raw.zst" "$BASE.$1.raw"; do
		[[ -f $f ]] && { echo "$f"; return 0; }
	done
	die "missing $BASE.$1.raw[.zst] (built without SplitArtifacts=partitions?)"
}
ROOT_SRC=$(pick root)
VERITY_SRC=$(pick root-verity)
[[ -f $UKI ]] || die "no UKI $UKI"
[[ -f $ROOTHASH_FILE ]] || die "no root hash $ROOTHASH_FILE"
ROOTHASH=$(tr -d '[:space:]' <"$ROOTHASH_FILE")

log "Build:    ${ID}_$VERSION"
log "UKI:      $(basename "$UKI") ($(($(stat -c %s "$UKI") / 1048576)) MiB)"
log "root:     $(basename "$ROOT_SRC") ($(($(stat -c %s "$ROOT_SRC") / 1048576)) MiB on disk)"
log "roothash: $ROOTHASH"

# --- what the UKI itself asks for ----------------------------------------------

if command -v objcopy >/dev/null; then
	CMDLINE=$(objcopy -O binary --only-section=.cmdline "$UKI" /dev/stdout 2>/dev/null | tr -d '\0')
else
	CMDLINE=$(grep -ao 'safespace\.netroot=[^ ]*\|roothash=[0-9a-f]*' "$UKI" | tr '\n' ' ')
	warn "objcopy not installed (binutils): only parts of the command line are checked"
fi
[[ " $CMDLINE " == *" roothash=$ROOTHASH "* ]] ||
	die "the UKI's command line does not carry roothash=$ROOTHASH: the files in mkosi.output/ do not belong together"
mapfile -t URLS < <(tr ' ' '\n' <<<"$CMDLINE" | sed -n 's/^safespace\.netroot=//p')
((${#URLS[@]})) || die "no safespace.netroot= in the UKI: this is not a network build (use ./build.sh network)"
log "netroot:  ${URLS[*]}"

# The initrd fetches <url>/root.img, so the directory must be named like the
# last path component of the URL.
DIRNAME=$(basename "${URLS[0]%/}")
[[ $DIRNAME == "$VERSION" ]] ||
	warn "the UKI loads its root from '.../$DIRNAME/', not from '.../$VERSION/'; publishing as '$DIRNAME'"
for url in "${URLS[@]}"; do
	[[ $(basename "${url%/}") == "$DIRNAME" ]] ||
		die "the UKI's netroot URLs end in different directories (${URLS[*]}); cannot publish one tree"
done

# --- signature ------------------------------------------------------------------

SIGNER=$(uefi_signer "$UKI" 2>/dev/null) && [[ -n $SIGNER ]] ||
	die "the UKI is not signed: the firmware will refuse it with Secure Boot on"
log "signed by: $(openssl x509 -noout -subject -nameopt oneline <<<"$SIGNER" | sed 's/^subject=//')"
log "           $(openssl x509 -noout -fingerprint -sha256 <<<"$SIGNER")"
db=$HERE/mkosi.extra/usr/share/safespace/secureboot/db.pem
if [[ -f $db ]]; then
	a=$(openssl x509 -in "$db" -noout -fingerprint -sha256)
	b=$(openssl x509 -noout -fingerprint -sha256 <<<"$SIGNER")
	[[ $a == "$b" ]] && log "           = the db certificate shipped in the image (safespace-seal enrolls it)" ||
		warn "the UKI is signed by a different key than the shipped db.pem; a sealed machine will not boot it"
fi

# --- write the tree -------------------------------------------------------------

DEST=$TREE/$DIRNAME
log "Writing $DEST"
mkdir -p "$DEST"
install -m 0644 "$UKI" "$DEST/boot.efi"
for pair in "$ROOT_SRC:root.img" "$VERITY_SRC:root.verity"; do
	src=${pair%:*} dst=$DEST/${pair#*:}
	if [[ $src == *.zst ]]; then
		log "  decompressing $(basename "$src") -> ${dst##*/}"
		zstd -dqf "$src" -o "$dst"
	else
		log "  copying $(basename "$src") -> ${dst##*/}"
		cp --reflink=auto "$src" "$dst"
	fi
	chmod 0644 "$dst"
done
printf '%s\n' "$ROOTHASH" >"$DEST/roothash"
printf '%s\n' "$CMDLINE" >"$DEST/cmdline"
chmod 0644 "$DEST/roothash" "$DEST/cmdline"
chmod 0755 "$TREE" "$DEST"

# The root hash comes from the signed UKI, so this checks that the files about
# to be served are exactly the ones that were signed. A client would notice
# too (and refuse to boot), but better here than on 50 machines.
log "Verifying root.img against the signed root hash (reads $(($(stat -c %s "$DEST/root.img") / 1048576)) MiB)"
veritysetup verify "$DEST/root.img" "$DEST/root.verity" "$ROOTHASH" ||
	die "dm-verity verification failed: root.img and root.verity do not match roothash=$ROOTHASH"
log "  root.img is exactly what the UKI was signed for"

if ((CURRENT)); then
	ln -sfn "$DIRNAME" "$TREE/.current.new"
	mv -T "$TREE/.current.new" "$TREE/current"
	log "current -> $DIRNAME"
fi

# --- copy to the server ---------------------------------------------------------

if [[ -n $RSYNC ]]; then
	command -v rsync >/dev/null || die "missing 'rsync'"
	log "Copying to $RSYNC"
	rsync -a --info=progress2 --chmod=D755,F644 "$DEST" "${RSYNC%/}/"
	((CURRENT)) && rsync -a "$TREE/current" "${RSYNC%/}/"
	log "Done. The server now serves .../$DIRNAME/ and current -> $DIRNAME"
fi

# --- prune ----------------------------------------------------------------------

if ((PRUNE > 0)); then
	keep=$(readlink "$TREE/current" 2>/dev/null || true)
	mapfile -t versions < <(find "$TREE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
	old=()
	for v in "${versions[@]:PRUNE}"; do
		[[ $v == "$keep" ]] && continue
		old+=("$v")
	done
	if ((${#old[@]})); then
		log "Pruning ${#old[@]} old version(s): ${old[*]}"
		if ((CONFIRM)); then
			read -rp "Delete them from $TREE? Type YES to continue: " answer
			[[ $answer == YES ]] || die "aborted"
		fi
		for v in "${old[@]}"; do rm -rf -- "$TREE/$v"; done
		[[ -n $RSYNC ]] && warn "deleted locally only; remove them on the server too (they stay bootable while they are there)"
	fi
fi

log "Netboot tree: $TREE"
ls -l "$TREE" | sed 's/^/    /'
