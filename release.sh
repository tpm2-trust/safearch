#!/usr/bin/env bash
# Release a build: bundle it, check it, push it to the distribution servers.
# Runs on the build host (the machine with the signing keys), as a normal user.
# A server holds exactly one release; pushing replaces it. The release serves
# both boot paths: machines boot boot.efi over the network, burn.sh writes
# sticks from it.
#
#   ./release.sh [--build BUILD] [--push TARGET]... [--builds DIR] [--stage DIR]
#
#   --build BUILD   the build to release, as ./build.sh list shows it
#                   (e.g. combined_20261019-0930). Releasing an older
#                   build again is how a release is rolled back.
#   (without)       the newest build
#   --builds DIR    where the builds are (default: mkosi.output; tests/vm.sh
#                   keeps its test builds apart). A build from elsewhere goes
#                   only where --push says, never to RELEASE_TARGETS: a test
#                   build carries the test key and must never reach a real server.
#   --stage DIR     where the release is staged (default: mkosi.release)
#   --push TARGET   distribution server to push to, repeatable. TARGET is the
#                   upload account, e.g. safespace@dist1.example.org (its ssh
#                   key only reaches the share, see server/setup.sh), or a
#                   local share directory, e.g. /srv/safespace/share. Without
#                   --push: RELEASE_TARGETS= of safespace.conf (this host's
#                   in safespace.local.conf); none at all = stage only.
#
# The bundle, mkosi.release/ (the newest release only): the build's parts as
# hardlinks (nothing is copied or unpacked) plus the release files:
#   boot.efi (signed UKI), systemd-boot.efi, layout.sfdisk; per combination
#   root-<name>.img, root-<name>.verity, roothash-<name>, manifest-<name>.json;
#   cmdline (the UKI's signed command line, readable), release.p7s (the release
#   file's signature by the db key, from the build), release (VERSION,
#   BUILD, COMBINATIONS, BUILT, SNAPSHOT, COMMIT, PACKAGES), SHA256SUMS
# It is checked here exactly as a server checks it (lib/verify.sh): Secure
# Boot signatures against the exported db.pem, every root image against its
# signed root hash, the stick's partition table. test-vm.sh --netboot serves
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

BUILD="" TARGETS=() STAGE_DIR=$HERE/mkosi.release
while (($#)); do
	case $1 in
		--build) BUILD=${2:?--build needs a build (./build.sh list)}; shift 2 ;;
		--push) TARGETS+=("${2:?--push needs a target}"); shift 2 ;;
		--builds) BUILDS_ROOT=$(readlink -f "${2:?--builds needs a directory}"); shift 2 ;;
		--stage) STAGE_DIR=$(readlink -f "${2:?--stage needs a directory}"); shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die "unknown option $1" ;;
	esac
done
# shellcheck source=lib/conf.sh
source "$HERE/lib/conf.sh"
conf_load "$HERE"
if [[ $BUILDS_ROOT == "$HERE/mkosi.output" ]]; then
	((${#TARGETS[@]})) || read -ra TARGETS <<<"$RELEASE_TARGETS"
elif ((${#TARGETS[@]} == 0)) && [[ -n $RELEASE_TARGETS ]]; then
	log "builds from ${BUILDS_ROOT#"$HERE"/}, not mkosi.output: not to RELEASE_TARGETS (only --push)"
fi
for cmd in sbverify objcopy veritysetup sha256sum openssl; do
	command -v "$cmd" >/dev/null || die "missing '$cmd' (pacman -S sbsigntools binutils cryptsetup openssl)"
done
((${#TARGETS[@]} == 0)) || command -v rsync >/dev/null || die "missing 'rsync' (pacman -S rsync)"

DB=$HERE/mkosi.extra/usr/share/safespace/secureboot/db.pem
[[ -f $DB ]] || die "no $DB: build with ./build.sh first (it exports the public keys)"

# --- pick the build ------------------------------------------------------------

if [[ -n $BUILD ]]; then
	BUILD=$(builds_find "$BUILD")
else
	BUILD=$(builds_newest)
	[[ -n $BUILD ]] || die "no build (run: sudo ./build.sh)"
fi
DIR=$(builds_dir "$BUILD")
VERSION=$(builds_info "$DIR" version)
COMBOS=$(builds_combo_names "$DIR")
[[ -n $COMBOS ]] || die "$DIR/build.json names no combinations"
verify_name_version "$VERSION" || die "invalid version '$VERSION' in $DIR/build.json"
log "Release $BUILD"
log "  combinations $COMBOS, built $(builds_info "$DIR" finished), snapshot $(builds_info "$DIR" snapshot), commit $(builds_info "$DIR" commit)$([[ $(builds_info "$DIR" uncommitted_changes) == yes ]] && echo ' + uncommitted changes'), $(builds_info "$DIR" packages) packages"
# Newer builds that were never released: maybe the one meant.
while IFS= read -r b; do
	[[ $b != "$BUILD" && $(builds_version_of "$b") > $VERSION && ! -s $(builds_dir "$b")/released.log ]] &&
		warn "a newer build is not released: $b (release it with --build $b)"
done < <(builds_all)

# --- bundle --------------------------------------------------------------------

DEST=$STAGE_DIR
[[ $DEST != / && $DEST != "$HERE" ]] || die "--stage $DEST: not a staging directory"
rm -rf "$DEST"
mkdir -p "$DEST"
PARTS=(boot.efi systemd-boot.efi layout.sfdisk)
for n in ${COMBOS//,/ }; do PARTS+=("root-$n.img" "root-$n.verity" "roothash-$n" "manifest-$n.json"); done
for f in "${PARTS[@]}"; do
	[[ -f $DIR/$f ]] || die "$DIR/$f missing"
	ln "$DIR/$f" "$DEST/$f" 2>/dev/null || cp --reflink=auto "$DIR/$f" "$DEST/$f"
done
uki_section "$DEST/boot.efi" .cmdline >"$DEST/cmdline"
echo >>"$DEST/cmdline"
# The release file and its signature, as the build wrote them.
for f in release release.p7s; do
	[[ -f $DIR/$f ]] || die "$DIR/$f missing"
	cp "$DIR/$f" "$DEST/$f"
done
(cd "$DEST" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum >SHA256SUMS)
chmod 0644 "$DEST"/{cmdline,release,release.p7s,SHA256SUMS}
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
((${#TARGETS[@]})) || log "No --push target: staged only (RELEASE_TARGETS= in safespace.local.conf, or --push)"
