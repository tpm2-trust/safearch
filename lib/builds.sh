# The builds on the build host. Sourced by build.sh, release.sh, burn.sh and
# test-vm.sh; expects die() and log(). Needs python3 (JSON).
#
# Layout: one directory per build (builds_finalize turns mkosi's output into
# it); the same parts serve a stick and the network:
#   mkosi.output/<groups>_<version>/
#     boot.efi            the signed UKI
#     root.img            the root partition (erofs, dm-verity data)
#     root.verity         its dm-verity hash tree
#     roothash            the root hash (also on the UKI's signed command line)
#     systemd-boot.efi    the signed systemd-boot (\EFI\BOOT\BOOTX64.EFI on a stick)
#     layout.sfdisk       a stick's partition table (lib/stick.sh)
#     manifest.json       the packages
#     systemd-stub.efi    the image's systemd-stub (only for build.sh without --groups; never released)
#     vnc-password        remotedesktop: the generated VNC password (0600)
#     build.json          what, when, from what (builds_write_info)
#     released.log        "<time> <target>" per push (release.sh)
# <groups> is the group set in its fixed order joined by "-" (base-remotedesktop),
# <version> the build time (YYYYMMDD-HHMM[SS][-debug]). The directory name is
# "the build": what list, release.sh --build and the servers show.
#
#   builds_id GROUPS VERSION      "base,docker" 20261019-0930 -> base-docker_20261019-0930
#   builds_all                    the complete builds, sorted (one group set after the other)
#   builds_dir BUILD              its directory
#   builds_find BUILD             the build, or die
#   builds_newest [GROUPS]        the newest complete build (of that group set)
#   builds_info DIR KEY           a value from build.json
#   builds_list                   the overview table
#   builds_show BUILD             details and package list
#   builds_diff A B               package differences of two builds
#   builds_prune KEEP YES         delete all but the newest KEEP per group set
#   builds_finalize DIR VERSION   mkosi's output -> the parts above
# A build is complete once build.json exists (written after a successful build).

BUILDS_ROOT=${BUILDS_ROOT:-$HERE/mkosi.output}
BUILDS_IMAGE_ID=safespace-arch

builds_id() { echo "${1//,/-}_$2"; }
builds_dir() { echo "$BUILDS_ROOT/$1"; }
builds_groups_of() { local g=${1%%_*}; echo "${g//-/,}"; } # BUILD -> groups
builds_version_of() { echo "${1#*_}"; }                     # BUILD -> version

builds_all() {
	local d
	for d in "$BUILDS_ROOT"/*_*/; do
		[[ -f $d/build.json ]] && basename "$d"
	done | LC_ALL=C sort
	return 0
}

builds_find() { # BUILD
	[[ $1 =~ ^[a-z-]+_[0-9][0-9A-Za-z._-]*$ && -f $BUILDS_ROOT/$1/build.json ]] || die "no build $1 (./build.sh list)"
	echo "$1"
}

# Newest by version (the build time), not by file time.
builds_newest() { # [GROUPS]
	local want=${1:-} b
	builds_all | while IFS= read -r b; do
		[[ -z $want || $(builds_groups_of "$b") == "$want" ]] || continue
		echo "$(builds_version_of "$b") $b"
	done | sort -r | awk 'NR == 1 { print $2 }'
}

builds_info() { # DIR KEY
	python3 -I -c '
import json, sys
v = json.load(open(sys.argv[1] + "/build.json")).get(sys.argv[2], "")
print(",".join(map(str, v)) if isinstance(v, list) else v)' "$1" "$2"
}

# The last push of a build: "<time> <target>", or nothing.
builds_last_release() { tail -n 1 "$1/released.log" 2>/dev/null || true; }

builds_list() {
	local b d rel
	printf '%-44s %-17s %-11s %5s %7s  %s\n' BUILD BUILT SNAPSHOT PKGS SIZE "LAST RELEASE"
	while IFS= read -r b; do
		d=$(builds_dir "$b")
		rel=$(builds_last_release "$d")
		printf '%-44s %-17s %-11s %5s %7s  %s\n' "$b" \
			"$(builds_info "$d" finished | cut -c1-16 | tr T ' ')" "$(builds_info "$d" snapshot)" \
			"$(builds_info "$d" packages)" "$(du -sh "$d" 2>/dev/null | cut -f1)" "${rel:--}"
	done < <(builds_all)
	# Directories without build.json: failed or running builds.
	find "$BUILDS_ROOT" -mindepth 1 -maxdepth 1 -type d ! -exec test -f '{}/build.json' \; -printf '%P (incomplete: no build.json)\n' 2>/dev/null |
		sed 's/^/  /'
	return 0
}

builds_show() { # BUILD
	local d
	d=$(builds_dir "$1")
	python3 -I - "$d" <<-'EOF'
		import json, sys, os
		d = sys.argv[1]
		info = json.load(open(d + "/build.json"))
		for k, v in info.items():
		    print(f"{k:20} {','.join(map(str, v)) if isinstance(v, list) else v}")
		if os.path.exists(d + "/manifest.json"):
		    pk = json.load(open(d + "/manifest.json"))["packages"]
		    print(f"\npackages ({len(pk)}):")
		    for p in sorted(pk, key=lambda p: p["name"]):
		        print(f"  {p['name']:40} {p['version']}")
	EOF
	[[ -f $d/released.log ]] && { echo; echo "released:"; sed 's/^/  /' "$d/released.log"; }
	return 0
}

builds_diff() { # BUILD BUILD
	python3 -I - "$BUILDS_ROOT/$1" "$BUILDS_ROOT/$2" <<-'EOF'
		import json, sys, os
		def pk(d):
		    m = d + "/manifest.json"
		    if not os.path.exists(m): sys.exit(f"no manifest.json in {d}")
		    return {p["name"]: p["version"] for p in json.load(open(m))["packages"]}
		a, b = pk(sys.argv[1]), pk(sys.argv[2])
		for n in sorted(set(a) | set(b)):
		    if n not in a: print(f"+ {n:40} {b[n]}")
		    elif n not in b: print(f"- {n:40} {a[n]}")
		    elif a[n] != b[n]: print(f"~ {n:40} {a[n]} -> {b[n]}")
		same = sum(1 for n in a if b.get(n) == a[n])
		print(f"({same} packages unchanged)")
	EOF
}

builds_prune() { # KEEP YES
	local keep=$1 yes=$2 g b d last=() del=() n
	# The build each target got last stays, whatever its age.
	while IFS= read -r b; do last+=("$b"); done < <(
		for d in "$BUILDS_ROOT"/*_*/; do
			[[ -f $d/released.log ]] || continue
			awk -v b="$(basename "$d")" '{ print $1, $2, b }' "$d/released.log"
		done | sort -k2,2 -k1,1r | awk '!seen[$2]++ { print $3 }')
	for g in $(builds_all | while IFS= read -r b; do builds_groups_of "$b"; done | sort -u); do
		n=0
		while IFS= read -r b; do
			n=$((n + 1))
			((n > keep)) || continue
			[[ " ${last[*]} " == *" $b "* ]] && { log "keeping $b (last release to a target)"; continue; }
			del+=("$b")
		done < <(builds_all | while IFS= read -r b; do
			[[ $(builds_groups_of "$b") == "$g" ]] && echo "$(builds_version_of "$b") $b"
		done | sort -r | awk '{ print $2 }')
	done
	# Leftovers of failed builds (no build.json), except one still being written.
	while IFS= read -r d; do
		[[ -n $(find "$d" -mmin -120 -print -quit) ]] || del+=("$(basename "$d")")
	done < <(find "$BUILDS_ROOT" -mindepth 1 -maxdepth 1 -type d ! -exec test -f '{}/build.json' \; -print 2>/dev/null)
	((${#del[@]})) || { log "nothing to prune (keeping $keep per group set)"; return 0; }
	for b in "${del[@]}"; do printf '  delete %s (%s)\n' "$b" "$(du -sh "$BUILDS_ROOT/$b" | cut -f1)"; done
	if ((!yes)); then
		read -rp "Delete these ${#del[@]} build(s)? Type YES: " answer
		[[ $answer == YES ]] || die "aborted"
	fi
	for b in "${del[@]}"; do rm -rf -- "${BUILDS_ROOT:?}/$b"; done
	log "deleted ${#del[@]} build(s)"
}

# build.json for a finished build (build.sh, as root, after mkosi succeeded).
builds_write_info() { # DIR, then KEY=VALUE pairs (VALUE with commas = a list for groups/netroot)
	local d=$1; shift
	python3 -I - "$d" "$@" <<-'EOF'
		import json, sys, os, glob
		d, pairs = sys.argv[1], sys.argv[2:]
		info = {}
		for p in pairs:
		    k, _, v = p.partition("=")
		    info[k] = [x for x in v.split(",") if x] if k in ("groups", "netroot", "combinations") else v
		ms = [d + "/manifest.json"] if os.path.exists(d + "/manifest.json") else sorted(glob.glob(d + "/manifest-*.json"))
		info["packages"] = sum(len(json.load(open(m))["packages"]) for m in ms)
		info["uki_bytes"] = os.path.getsize(d + "/boot.efi") if os.path.exists(d + "/boot.efi") else 0
		info["root_bytes"] = sum(os.path.getsize(f) for f in glob.glob(d + "/root*.img"))
		with open(d + "/build.json", "w") as f:
		    json.dump(info, f, indent=2)
		    f.write("\n")
	EOF
}

# mkosi writes <ImageId>_<version>.{efi,root.raw,root-verity.raw,roothash,
# manifest,raw,...}; keep only the parts (see the top), under short names. The
# partition table and the signed systemd-boot come out of the whole disk image
# first; then the image and mkosi's separate initrd copy go: nothing is kept
# or shipped twice.
builds_finalize() { # DIR VERSION
	local d=$1 b f off
	b=$d/${BUILDS_IMAGE_ID}_$2
	for f in efi:boot.efi root.raw:root.img root-verity.raw:root.verity roothash:roothash manifest:manifest.json; do
		[[ -f $b.${f%%:*} ]] || die "builds_finalize: mkosi wrote no $(basename "$b").${f%%:*}"
		mv -f "$b.${f%%:*}" "$d/${f#*:}"
	done
	[[ -f $b.vnc-password ]] && mv -f "$b.vnc-password" "$d/vnc-password"
	[[ -f $b.systemd-stub ]] && mv -f "$b.systemd-stub" "$d/systemd-stub.efi"
	[[ -f $b.raw ]] || die "builds_finalize: no disk image $(basename "$b").raw"
	# The table as systemd-repart wrote it (types, UUIDs derived from the root
	# hash, sizes, attributes), without the image's file name.
	sfdisk -d "$b.raw" | sed -e '/^device:/d' -e 's|^[^ ]* : ||' >"$d/layout.sfdisk"
	off=$(($(awk -F'[=,]' 'toupper($0) ~ /TYPE=C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ { gsub(/ /, ""); print $2; exit }' "$d/layout.sfdisk") * 512))
	mcopy -n -i "$b.raw@@$off" ::/EFI/BOOT/BOOTX64.EFI "$d/systemd-boot.efi" ||
		die "builds_finalize: no \\EFI\\BOOT\\BOOTX64.EFI in the ESP"
	rm -f -- "$b.raw" "$b" "$b".*.raw "$d/initrd" "$d/initrd.cpio.zst"
	chmod 0644 "$d"/{boot.efi,root.img,root.verity,roothash,manifest.json,systemd-boot.efi,layout.sfdisk}
}
