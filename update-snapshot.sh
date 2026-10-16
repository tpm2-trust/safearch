#!/usr/bin/env bash
# Move the pinned Arch Linux Archive snapshot to the newest available day.
# The next `sudo mkosi build` then installs the updated packages (only changed
# ones are downloaded; the incremental cache is rebuilt automatically).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

file=mkosi.conf.d/20-snapshot.conf
old=$(sed -n 's/^Snapshot=//p' "$file")
new=$(mkosi latest-snapshot)
[[ $new =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]] || { echo "unexpected snapshot id: $new" >&2; exit 1; }
if [[ $new == "$old" ]]; then
	echo "Snapshot already at $new"
	exit 0
fi
sed -i "s|^Snapshot=.*|Snapshot=$new|" "$file"
echo "Snapshot: $old -> $new"
