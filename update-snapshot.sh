#!/usr/bin/env bash
# Move the pinned Arch Linux Archive snapshot (SNAPSHOT= in repos.conf) to the
# newest available day. The next `sudo ./build.sh` then installs the
# updated packages (only changed ones are downloaded; the incremental cache is
# rebuilt automatically).
#
# The newest day is asked from MIRROR (repos.conf / repos.local.conf), which
# then has to be an Arch Linux Archive mirror, else from archive.archlinux.org.
# SNAPSHOT=latest in repos.conf is replaced by that day, i.e. pinned again.
# A SNAPSHOT= in repos.local.conf still wins over the new value.
set -Eeuo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib/repos.sh
source "$HERE/lib/repos.sh"
repos_load "$HERE"

file=$HERE/repos.conf
old=$(sed -n 's/^SNAPSHOT=//p' "$file")
[[ -n $old ]] || die "no SNAPSHOT= line in $file"
new=$(mkosi -C "$HERE" ${MIRROR:+--mirror="$MIRROR"} latest-snapshot) ||
	die "mkosi latest-snapshot failed (MIRROR=${MIRROR:-default}: an archive mirror serves <MIRROR>/repos/last/lastsync)"
[[ $new =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]] || die "unexpected snapshot id: $new"
if [[ $new == "$old" ]]; then
	log "Snapshot already at $new"
	exit 0
fi
sed -i "s|^SNAPSHOT=.*|SNAPSHOT=$new|" "$file"
log "Snapshot: $old -> $new"
[[ -f $HERE/repos.local.conf ]] && grep -q '^[[:space:]]*SNAPSHOT=' "$HERE/repos.local.conf" &&
	log "note: repos.local.conf sets its own SNAPSHOT=, which still overrides this"
exit 0
