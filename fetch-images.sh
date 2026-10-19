#!/usr/bin/env bash
# Download the images listed in docker-images.txt as docker-archive files into
# mkosi.profiles/docker/mkosi.extra/usr/share/safespace/docker-images/, where a
# build with the docker group (--groups base,docker) puts them
# into the dm-verity protected root. At boot, safespace-docker-images.service
# loads them into Docker's storage on the data disk (/opt/docker).
# Needs skopeo (pacman -S skopeo), no root and no running Docker.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

out=mkosi.profiles/docker/mkosi.extra/usr/share/safespace/docker-images
command -v skopeo >/dev/null || { echo "install skopeo first: sudo pacman -S skopeo" >&2; exit 1; }
rm -rf "$out"
mkdir -p "$out"
list=$out/images.list
echo "# <archive> <image-id> <reference>  (written by fetch-images.sh)" >"$list"

while read -r name src _; do
	[[ -z $name || $name == \#* ]] && continue
	[[ -n ${src:-} ]] || { echo "docker-images.txt: no source for $name" >&2; exit 1; }
	[[ $name == *:* ]] || name=$name:latest
	[[ $src == *@sha256:* ]] || echo "WARNING: $src is not pinned by digest; rebuilds may ship a different image" >&2
	archive=$(tr -c 'A-Za-z0-9._-' '_' <<<"$name" | sed 's/_$//').tar
	echo "==> $name <- $src"
	skopeo copy --quiet --override-os linux --override-arch amd64 \
		"docker://$src" "docker-archive:$out/$archive:$name"
	# The image ID Docker assigns is the digest of the image config.
	config=$(tar -xOf "$out/$archive" manifest.json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["Config"])')
	id=sha256:$(basename "$config" .json | sed 's|^sha256:||')
	echo "$archive $id $name" >>"$list"
	echo "    $id, $(du -h "$out/$archive" | cut -f1)"
done <docker-images.txt

n=$(grep -vc '^#' "$list" || true)
echo "$n image(s) in $out"
