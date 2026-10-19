#!/usr/bin/env bash
# Release a build: bundle it, check it, push it to the distribution servers.
# Runs on the build host (the machine with the signing keys), as a normal user.
#
#   ./release.sh network|usb [--version VER] [--channel NAME] [--push TARGET]... [--prune N]
#
#   --version VER   the build to release (default: the newest of the variant
#                   in mkosi.output/)
#   --channel NAME  the channel the distribution servers switch to this release
#                   as soon as they have verified it (default: current). One
#                   channel per kind of machine, e.g. "current" and "desktop".
#   --push TARGET   distribution server to push to, repeatable. TARGET is the
#                   upload account, e.g. safespace@dist1.example.org (its ssh
#                   key only reaches the share, see server/setup.sh), or a
#                   local share directory, e.g. /srv/safespace/share. Without
#                   --push: RELEASE_TARGETS= from release.conf (gitignored,
#                   see release.conf.example); none at all = stage only.
#   --prune N       keep only the newest N releases in mkosi.release/ (the
#                   servers prune themselves, KEEP= in their server.conf)
#
# The bundle, mkosi.release/<variant>/<version>/:
#   network  boot.efi (signed UKI), root.img, root.verity, roothash, cmdline
#   usb      image.raw.zst (the whole stick image), roothash
#   both     release (VARIANT, VERSION, GROUPS, CHANNEL), manifest.json,
#            SHA256SUMS
# It is checked here exactly as a server checks it (lib/verify.sh): Secure
# Boot signature against the exported db.pem, root image against the signed
# root hash. mkosi.release/<variant>/<channel> points at the newest release of
# that channel (test-vm.sh --netboot and netstick.sh use it).
#
# Pushing: rsync over ssh, the release directory first, then the marker
# .pending/<variant>_<version>. The server's import service starts on the
# marker, verifies the release and switches the channel. Released versions
# are immutable on the server (rsync there may not overwrite or delete).
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m==> WARNING:\e[0m %s\n' "$*" >&2; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; }
# shellcheck source=lib/verify.sh
source "$HERE/lib/verify.sh"

VARIANT=${1:-}
case $VARIANT in
	network | usb) shift ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; die "first argument: network or usb" ;;
esac
VERSION="" CHANNEL=current PRUNE=0 TARGETS=()
while (($#)); do
	case $1 in
		--version) VERSION=${2:?--version needs a build version}; shift 2 ;;
		--channel) CHANNEL=${2:?--channel needs a name}; shift 2 ;;
		--push) TARGETS+=("${2:?--push needs a target}"); shift 2 ;;
		--prune) PRUNE=${2:?--prune needs a number}; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die "unknown option $1" ;;
	esac
done
verify_name_channel "$CHANNEL" || die "invalid channel '$CHANNEL' (lowercase letters, digits, -; starting with a letter)"
[[ $PRUNE =~ ^[0-9]+$ ]] || die "--prune needs a number"
if ((${#TARGETS[@]} == 0)) && [[ -f $HERE/release.conf ]]; then
	targets=$(sed -n 's/^RELEASE_TARGETS=//p' "$HERE/release.conf" | tail -1 | tr -d '"'"'")
	read -ra TARGETS <<<"$targets"
fi
for cmd in sbverify objcopy veritysetup sha256sum zstd sfdisk mcopy openssl; do
	command -v "$cmd" >/dev/null || die "missing '$cmd' (pacman -S sbsigntools binutils cryptsetup zstd util-linux mtools openssl)"
done
((${#TARGETS[@]} == 0)) || command -v rsync >/dev/null || die "missing 'rsync'"

OUT=$HERE/mkosi.output
ID=safespace-arch-$VARIANT
DB=$HERE/mkosi.extra/usr/share/safespace/secureboot/db.pem
[[ -f $DB ]] || die "no $DB: build with ./build.sh first (it exports the public keys)"

# --- pick the build ------------------------------------------------------------

[[ $VARIANT == network ]] && main=.efi || main=.raw.zst
if [[ -z $VERSION ]]; then
	newest=$(find "$OUT" -maxdepth 1 -name "${ID}_*$main" -printf '%T@ %p\n' 2>/dev/null |
		sort -nr | awk 'NR == 1 { print $2 }')
	[[ -n $newest ]] || die "no $VARIANT build in mkosi.output/ (run: sudo ./build.sh $VARIANT)"
	VERSION=$(basename "$newest" "$main"); VERSION=${VERSION#"${ID}_"}
fi
verify_name_version "$VERSION" || die "invalid version '$VERSION'"
BASE=$OUT/${ID}_$VERSION
[[ -f $BASE.roothash ]] || die "no $BASE.roothash"
GROUPS_SET=$(cat "$BASE.groups" 2>/dev/null || true)
[[ -n $GROUPS_SET ]] || { GROUPS_SET=unknown; warn "no $(basename "$BASE").groups (built before package groups existed)"; }
log "Release ${ID}_$VERSION (groups $GROUPS_SET) for channel $CHANNEL"

# --- bundle --------------------------------------------------------------------

STAGE=$HERE/mkosi.release/$VARIANT
DEST=$STAGE/$VERSION
rm -rf "$DEST"
mkdir -p "$DEST"
unpack() { # SRC-BASE (without .raw[.zst]) DEST-FILE
	if [[ -f $1.raw.zst ]]; then
		zstd -dqf "$1.raw.zst" -o "$2"
	elif [[ -f $1.raw ]]; then
		cp --reflink=auto "$1.raw" "$2"
	else
		die "missing $1.raw[.zst] (built without SplitArtifacts=partitions?)"
	fi
}
if [[ $VARIANT == network ]]; then
	[[ -f $BASE.efi ]] || die "no UKI $BASE.efi"
	install -m 0644 "$BASE.efi" "$DEST/boot.efi"
	log "  unpacking root.img and root.verity"
	unpack "$BASE.root" "$DEST/root.img"
	unpack "$BASE.root-verity" "$DEST/root.verity"
	uki_cmdline "$DEST/boot.efi" >"$DEST/cmdline"
	echo >>"$DEST/cmdline"
else
	[[ -f $BASE.raw.zst ]] || die "no $BASE.raw.zst"
	cp --reflink=auto "$BASE.raw.zst" "$DEST/image.raw.zst"
fi
tr -d '[:space:]' <"$BASE.roothash" >"$DEST/roothash"
echo >>"$DEST/roothash"
[[ -f $BASE.manifest ]] && cp "$BASE.manifest" "$DEST/manifest.json"
printf 'VARIANT=%s\nVERSION=%s\nGROUPS=%s\nCHANNEL=%s\n' "$VARIANT" "$VERSION" "$GROUPS_SET" "$CHANNEL" >"$DEST/release"
(cd "$DEST" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum >SHA256SUMS)
chmod 0644 "$DEST"/*
chmod 0755 "$DEST"

# --- check it as a server will ---------------------------------------------------

log "Checking the release (as the distribution servers do)"
tmp=$(mktemp -d "$HERE/mkosi.release/.verify.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
verify_release "$DEST" "$VARIANT" "$VERSION" "$DB" "$tmp" || die "the release does not pass the checks; nothing pushed"
ln -sfn "$VERSION" "$STAGE/.$CHANNEL.new"
mv -T "$STAGE/.$CHANNEL.new" "$STAGE/$CHANNEL"
log "Staged: $DEST ($(du -sh "$DEST" | cut -f1)), $CHANNEL -> $VERSION"

# --- push ------------------------------------------------------------------------

marker=$HERE/mkosi.release/.pending/${VARIANT}_$VERSION
mkdir -p "$(dirname "$marker")"
: >"$marker"
for target in "${TARGETS[@]}"; do
	# user@host -> user@host: (paths relative to the share, the server's rrsync
	# confines them); a local directory stays as it is.
	if [[ $target == /* || $target == ./* ]]; then
		remote=${target%/}/
		[[ -d $remote.pending ]] || die "$target is not a share (no .pending/; run server/setup.sh there)"
	elif [[ $target == *:* ]]; then
		remote=${target%/}
		[[ $remote == *: ]] || remote+=/
	else
		remote=$target:
	fi
	log "Pushing to $target"
	rsync -rtp --chmod=D755,F644 --info=progress2 "$DEST" "$remote$VARIANT/" ||
		die "upload to $target failed (a version already on the server cannot be replaced: release a new build)"
	rsync -rtp --chmod=F644 "$marker" "$remote.pending/" || die "could not hand the release over on $target"
	log "  $target verifies and activates it now (journalctl -u safespace-netboot-import there)"
done
rm -f "$marker"
((${#TARGETS[@]})) || log "No --push target: staged only (RELEASE_TARGETS= in release.conf, or --push)"

# --- prune the local stage --------------------------------------------------------

if ((PRUNE > 0)); then
	mapfile -t keep < <(find "$STAGE" -mindepth 1 -maxdepth 1 -type l -printf '%l\n')
	mapfile -t versions < <(find "$STAGE" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | sort -r)
	for v in "${versions[@]:PRUNE}"; do
		[[ " ${keep[*]} " == *" $v "* ]] && continue
		log "pruning mkosi.release/$VARIANT/$v"
		rm -rf -- "${STAGE:?}/$v"
	done
fi
