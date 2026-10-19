#!/usr/bin/env bash
# Release a build: bundle it, check it, push it to the distribution servers.
# Runs on the build host (the machine with the signing keys), as a normal user.
# A server holds exactly one release; pushing replaces it. The release serves
# both boot paths: machines boot boot.efi over the network, burn.sh writes
# sticks from it.
#
#   ./release.sh [--build BUILD | --groups LIST] [--push TARGET]...
#                [--builds DIR] [--stage DIR]
#
#   --build BUILD   the build to release, as ./build.sh list shows it
#                   (e.g. base-remotedesktop_20261019-0930). Releasing an older
#                   build again is how a release is rolled back.
#   --groups LIST   the newest build with exactly this group set ("combined":
#                   the newest whole-stack build)
#   (neither)       the newest build, whatever its groups
#   --builds DIR    where the builds are (default: mkosi.output; tests/vm.sh
#                   keeps its test builds apart)
#   --stage DIR     where the release is staged (default: mkosi.release)
#   --push TARGET   distribution server to push to, repeatable. TARGET is the
#                   upload account, e.g. safespace@dist1.example.org (its ssh
#                   key only reaches the share, see server/setup.sh), or a
#                   local share directory, e.g. /srv/safespace/share. Without
#                   --push: RELEASE_TARGETS= from release.conf (gitignored,
#                   see release.conf.example); none at all = stage only.
#
# The bundle, mkosi.release/ (the newest release only): the build's parts as
# hardlinks (nothing is copied or unpacked) plus the release files:
#   boot.efi (signed UKI), root.img, root.verity, roothash, systemd-boot.efi,
#   layout.sfdisk, manifest.json; cmdline (the UKI's signed command line,
#   readable), release (VERSION, BUILD, GROUPS, BUILT, SNAPSHOT, COMMIT,
#   PACKAGES), SHA256SUMS
#   a combined build (build.sh without --groups): root-<name>.img, root-<name>.verity,
#   roothash-<name>, manifest-<name>.json per combination instead of the single
#   root, and COMBINATIONS= in release
# It is checked here exactly as a server checks it (lib/verify.sh): Secure
# Boot signatures against the exported db.pem, root image against the signed
# root hash, the stick's partition table. test-vm.sh --netboot serves
# mkosi.release/.
#
# Pushing: rsync over ssh into the share. --delay-updates collects
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

case ${1:-} in
	network | usb) die "there are no variants any more: one release serves sticks and the network ($0 [--build ...])" ;;
esac
BUILD="" WANT_GROUPS="" TARGETS=() STAGE_DIR=$HERE/mkosi.release
while (($#)); do
	case $1 in
		--build) BUILD=${2:?--build needs a build (./build.sh list)}; shift 2 ;;
		--groups) WANT_GROUPS=${2:?--groups needs a comma-separated list}; shift 2 ;;
		--push) TARGETS+=("${2:?--push needs a target}"); shift 2 ;;
		--builds) BUILDS_ROOT=$(readlink -f "${2:?--builds needs a directory}"); shift 2 ;;
		--stage) STAGE_DIR=$(readlink -f "${2:?--stage needs a directory}"); shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die "unknown option $1" ;;
	esac
done
if ((${#TARGETS[@]} == 0)) && [[ -f $HERE/release.conf ]]; then
	targets=$(sed -n 's/^RELEASE_TARGETS=//p' "$HERE/release.conf" | tail -1 | tr -d '"'"'")
	read -ra TARGETS <<<"$targets"
fi
for cmd in sbverify objcopy veritysetup sha256sum openssl; do
	command -v "$cmd" >/dev/null || die "missing '$cmd' (pacman -S sbsigntools binutils cryptsetup openssl)"
done
((${#TARGETS[@]} == 0)) || command -v rsync >/dev/null || die "missing 'rsync' (pacman -S rsync)"

DB=$HERE/mkosi.extra/usr/share/safespace/secureboot/db.pem
[[ -f $DB ]] || die "no $DB: build with ./build.sh first (it exports the public keys)"

# --- pick the build ------------------------------------------------------------

[[ -z $BUILD || -z $WANT_GROUPS ]] || die "--build or --groups, not both"
if [[ -n $WANT_GROUPS ]]; then
	if [[ ${WANT_GROUPS,,} == combined ]]; then
		WANT_GROUPS=combined
	else
		groups_parse "$WANT_GROUPS"
		WANT_GROUPS=$(IFS=,; echo "${SAFESPACE_GROUPS[*]}")
	fi
	BUILD=$(builds_newest "$WANT_GROUPS")
	[[ -n $BUILD ]] || die "no build with groups $WANT_GROUPS (./build.sh list)"
elif [[ -n $BUILD ]]; then
	BUILD=$(builds_find "$BUILD")
else
	BUILD=$(builds_newest)
	[[ -n $BUILD ]] || die "no build (run: sudo ./build.sh)"
fi
DIR=$(builds_dir "$BUILD")
VERSION=$(builds_info "$DIR" version)
GROUPS_SET=$(builds_info "$DIR" groups)
verify_name_version "$VERSION" || die "invalid version '$VERSION' in $DIR/build.json"
log "Release $BUILD"
log "  groups $GROUPS_SET, built $(builds_info "$DIR" finished), snapshot $(builds_info "$DIR" snapshot), commit $(builds_info "$DIR" commit)$([[ $(builds_info "$DIR" uncommitted_changes) == yes ]] && echo ' + uncommitted changes'), $(builds_info "$DIR" packages) packages"
# Newer builds of other group sets that were never released: maybe the one meant.
while IFS= read -r b; do
	[[ $b != "$BUILD" && $(builds_version_of "$b") > $VERSION && ! -s $(builds_dir "$b")/released.log ]] &&
		warn "a newer build is not released: $b (release it with --build $b)"
done < <(builds_all)

# --- bundle --------------------------------------------------------------------

DEST=$STAGE_DIR
[[ $DEST != / && $DEST != "$HERE" ]] || die "--stage $DEST: not a staging directory"
rm -rf "$DEST"
mkdir -p "$DEST"
# A combined build (build.sh without --groups) has one root per combination.
COMBOS=$(builds_info "$DIR" combinations | tr ',' '\n' | cut -d: -f1 | tr '\n' ',')
COMBOS=${COMBOS%,}
PARTS=(boot.efi systemd-boot.efi layout.sfdisk)
if [[ -n $COMBOS ]]; then
	for n in ${COMBOS//,/ }; do PARTS+=("root-$n.img" "root-$n.verity" "roothash-$n" "manifest-$n.json"); done
else
	PARTS+=(root.img root.verity roothash manifest.json)
fi
for f in "${PARTS[@]}"; do
	[[ -f $DIR/$f ]] || die "$DIR/$f missing (a build from before the parts layout? rebuild)"
	ln "$DIR/$f" "$DEST/$f" 2>/dev/null || cp --reflink=auto "$DIR/$f" "$DEST/$f"
done
uki_cmdline "$DEST/boot.efi" >"$DEST/cmdline"
echo >>"$DEST/cmdline"
{
	echo "VERSION=$VERSION"
	echo "BUILD=$BUILD"
	echo "GROUPS=$GROUPS_SET"
	echo "BUILT=$(builds_info "$DIR" finished)"
	echo "SNAPSHOT=$(builds_info "$DIR" snapshot)"
	echo "COMMIT=$(builds_info "$DIR" commit)$([[ $(builds_info "$DIR" uncommitted_changes) == yes ]] && echo +uncommitted)"
	echo "PACKAGES=$(builds_info "$DIR" packages)"
	[[ -z $COMBOS ]] || echo "COMBINATIONS=$COMBOS"
} >"$DEST/release"
(cd "$DEST" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum >SHA256SUMS)
chmod 0644 "$DEST"/{cmdline,release,SHA256SUMS}
chmod 0755 "$DEST"

# --- check it as a server will ---------------------------------------------------

log "Checking the release (as the distribution servers do)"
verify_release "$DEST" "$DB" || die "the release does not pass the checks; nothing pushed"
log "Staged: $DEST ($(du -sh "$DEST" | cut -f1))"

# --- push ------------------------------------------------------------------------

for target in "${TARGETS[@]}"; do
	# user@host -> user@host: (paths relative to the share, the server's rrsync
	# confines them); a local directory stays as it is.
	if [[ $target == /* || $target == ./* ]]; then
		remote=${target%/}/
		[[ -d $remote && -w $remote ]] || die "$target is no writable share directory (run server/setup.sh there)"
	elif [[ $target == *:* ]]; then
		remote=${target%/}
		[[ $remote == *: ]] || remote+=/
	else
		remote=$target:
	fi
	log "Pushing to $target"
	rsync -rtp --chmod=D755,F644 --delay-updates --info=progress2 --exclude=release "$DEST/" "$remote" ||
		die "upload to $target failed"
	rsync -rtp --chmod=F644 "$DEST/release" "$remote" || die "upload of release to $target failed"
	echo "$(date -Is) $target" >>"$DIR/released.log"
	log "  $target now serves $BUILD and checks it (there: safespace-netboot status)"
done
((${#TARGETS[@]})) || log "No --push target: staged only (RELEASE_TARGETS= in release.conf, or --push)"
