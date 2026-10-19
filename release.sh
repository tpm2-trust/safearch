#!/usr/bin/env bash
# Release a build: bundle it, check it, push it to the distribution servers.
# Runs on the build host (the machine with the signing keys), as a normal user.
# A server holds exactly one release per variant; pushing replaces it.
#
#   ./release.sh network|usb [--build BUILD | --groups LIST] [--push TARGET]...
#
#   --build BUILD   the build to release, as ./build.sh list shows it
#                   (e.g. base-remotedesktop_20261019-0930). Releasing an older
#                   build again is how a release is rolled back.
#   --groups LIST   the newest build with exactly this group set
#   (neither)       the newest build of the variant, whatever its groups
#   --push TARGET   distribution server to push to, repeatable. TARGET is the
#                   upload account, e.g. safespace@dist1.example.org (its ssh
#                   key only reaches the share, see server/setup.sh), or a
#                   local share directory, e.g. /srv/safespace/share. Without
#                   --push: RELEASE_TARGETS= from release.conf (gitignored,
#                   see release.conf.example); none at all = stage only.
#
# The bundle, mkosi.release/<variant>/ (the newest release only):
#   network  boot.efi (signed UKI), root.img, root.verity, roothash, cmdline
#   usb      image.raw.zst (the whole stick image), roothash
#   both     release (VARIANT, VERSION, BUILD, GROUPS, BUILT, SNAPSHOT, COMMIT,
#            PACKAGES), manifest.json, SHA256SUMS
# It is checked here exactly as a server checks it (lib/verify.sh): Secure
# Boot signature against the exported db.pem, root image against the signed
# root hash. test-vm.sh --netboot serves mkosi.release/network/.
#
# Pushing: rsync over ssh into <share>/<variant>/. --delay-updates collects
# the new files in a temp directory and renames them all at the end, so the
# switch takes milliseconds and a download already running finishes on the
# old file. `release` goes last: it is what the server's verify unit waits for.
# Every push is appended to the build's released.log (./build.sh list).
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m==> WARNING:\e[0m %s\n' "$*" >&2; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; }
# shellcheck source=lib/verify.sh
source "$HERE/lib/verify.sh"
# shellcheck source=lib/builds.sh
source "$HERE/lib/builds.sh"
# shellcheck source=lib/groups.sh
source "$HERE/lib/groups.sh"

VARIANT=${1:-}
case $VARIANT in
	network | usb) shift ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; die "first argument: network or usb" ;;
esac
BUILD="" WANT_GROUPS="" TARGETS=()
while (($#)); do
	case $1 in
		--build) BUILD=${2:?--build needs a build (./build.sh list)}; shift 2 ;;
		--groups) WANT_GROUPS=${2:?--groups needs a comma-separated list}; shift 2 ;;
		--push) TARGETS+=("${2:?--push needs a target}"); shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die "unknown option $1" ;;
	esac
done
if ((${#TARGETS[@]} == 0)) && [[ -f $HERE/release.conf ]]; then
	targets=$(sed -n 's/^RELEASE_TARGETS=//p' "$HERE/release.conf" | tail -1 | tr -d '"'"'")
	read -ra TARGETS <<<"$targets"
fi
for cmd in sbverify objcopy veritysetup sha256sum zstd sfdisk mcopy openssl; do
	command -v "$cmd" >/dev/null || die "missing '$cmd' (pacman -S sbsigntools binutils cryptsetup zstd util-linux mtools openssl)"
done
((${#TARGETS[@]} == 0)) || command -v rsync >/dev/null || die "missing 'rsync' (pacman -S rsync)"

ID=safespace-arch-$VARIANT
DB=$HERE/mkosi.extra/usr/share/safespace/secureboot/db.pem
[[ -f $DB ]] || die "no $DB: build with ./build.sh first (it exports the public keys)"

# --- pick the build ------------------------------------------------------------

[[ -z $BUILD || -z $WANT_GROUPS ]] || die "--build or --groups, not both"
if [[ -n $WANT_GROUPS ]]; then
	groups_parse "$WANT_GROUPS"
	WANT_GROUPS=$(IFS=,; echo "${SAFESPACE_GROUPS[*]}")
	BUILD=$(builds_newest "$VARIANT" "$WANT_GROUPS")
	[[ -n $BUILD ]] || die "no $VARIANT build with groups $WANT_GROUPS (./build.sh list)"
elif [[ -n $BUILD ]]; then
	BUILD=${BUILD#"$VARIANT"/}
	[[ -f $(builds_dir "$VARIANT" "$BUILD")/build.json ]] || die "no $VARIANT build $BUILD (./build.sh list $VARIANT)"
else
	BUILD=$(builds_newest "$VARIANT")
	[[ -n $BUILD ]] || die "no $VARIANT build (run: sudo ./build.sh $VARIANT)"
fi
DIR=$(builds_dir "$VARIANT" "$BUILD")
VERSION=$(builds_info "$DIR" version)
GROUPS_SET=$(builds_info "$DIR" groups)
verify_name_version "$VERSION" || die "invalid version '$VERSION' in $DIR/build.json"
BASE=$DIR/${ID}_$VERSION
[[ -f $BASE.roothash ]] || die "no $BASE.roothash"
log "Release $VARIANT/$BUILD"
log "  groups $GROUPS_SET, built $(builds_info "$DIR" finished), snapshot $(builds_info "$DIR" snapshot), commit $(builds_info "$DIR" commit)$([[ $(builds_info "$DIR" uncommitted_changes) == yes ]] && echo ' + uncommitted changes'), $(builds_info "$DIR" packages) packages"
# Newer builds of other group sets that were never released: maybe the one meant.
while IFS=/ read -r _ b; do
	[[ $b != "$BUILD" && $(builds_version_of "$b") > $VERSION && ! -s $(builds_dir "$VARIANT" "$b")/released.log ]] &&
		warn "a newer build is not released: $b (release it with --build $b)"
done < <(builds_all "$VARIANT")

# --- bundle --------------------------------------------------------------------

DEST=$HERE/mkosi.release/$VARIANT
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
{
	echo "VARIANT=$VARIANT"
	echo "VERSION=$VERSION"
	echo "BUILD=$BUILD"
	echo "GROUPS=$GROUPS_SET"
	echo "BUILT=$(builds_info "$DIR" finished)"
	echo "SNAPSHOT=$(builds_info "$DIR" snapshot)"
	echo "COMMIT=$(builds_info "$DIR" commit)$([[ $(builds_info "$DIR" uncommitted_changes) == yes ]] && echo +uncommitted)"
	echo "PACKAGES=$(builds_info "$DIR" packages)"
} >"$DEST/release"
(cd "$DEST" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum >SHA256SUMS)
chmod 0644 "$DEST"/*
chmod 0755 "$DEST"

# --- check it as a server will ---------------------------------------------------

log "Checking the release (as the distribution servers do)"
tmp=$(mktemp -d -t safespace-verify.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
verify_release "$DEST" "$VARIANT" "$DB" "$tmp" || die "the release does not pass the checks; nothing pushed"
log "Staged: $DEST ($(du -sh "$DEST" | cut -f1))"

# --- push ------------------------------------------------------------------------

for target in "${TARGETS[@]}"; do
	# user@host -> user@host: (paths relative to the share, the server's rrsync
	# confines them); a local directory stays as it is.
	if [[ $target == /* || $target == ./* ]]; then
		remote=${target%/}/
		[[ -d $remote$VARIANT ]] || die "$target is not a share (no $VARIANT/; run server/setup.sh there)"
	elif [[ $target == *:* ]]; then
		remote=${target%/}
		[[ $remote == *: ]] || remote+=/
	else
		remote=$target:
	fi
	log "Pushing to $target"
	rsync -rtp --chmod=D755,F644 --delay-updates --info=progress2 --exclude=release "$DEST/" "$remote$VARIANT/" ||
		die "upload to $target failed"
	rsync -rtp --chmod=F644 "$DEST/release" "$remote$VARIANT/" || die "upload of release to $target failed"
	echo "$(date -Is) $target" >>"$DIR/released.log"
	log "  $target now serves $BUILD and checks it (there: safespace-netboot status)"
done
((${#TARGETS[@]})) || log "No --push target: staged only (RELEASE_TARGETS= in release.conf, or --push)"
