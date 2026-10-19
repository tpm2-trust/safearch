# The builds on the build host. Sourced by build.sh and release.sh; expects
# die() and log(). Needs python3 (JSON).
#
# Layout: one directory per build,
#   mkosi.output/<variant>/<groups>_<version>/
#     build.json                       what, when, from what (builds_write_info)
#     released.log                     "<time> <target>" per push (release.sh)
#     safespace-arch-<variant>_<version>.*   mkosi's output
# <groups> is the group set in its fixed order joined by "-" (base-remotedesktop),
# <version> the build time (YYYYMMDD-HHMM[SS][-debug]). The directory name is
# "the build": what list, release.sh --build and the servers show.
#
#   builds_id GROUPS VERSION      "base,docker" 20261019-0930 -> base-docker_20261019-0930
#   builds_all [VARIANT]          "<variant>/<build>" of complete builds, sorted
#   builds_dir VARIANT BUILD      its directory
#   builds_find BUILD             "<variant>/<build>" for a build name (or variant/build)
#   builds_newest VARIANT [GROUPS]  the newest complete build (of that group set)
#   builds_info DIR KEY           a value from build.json
#   builds_list [VARIANT]         the overview table
#   builds_show VARIANT BUILD     details and package list
#   builds_diff A B               package differences of two builds
#   builds_prune KEEP YES         delete all but the newest KEEP per variant and group set
# A build is complete once build.json exists (written after a successful build).

BUILDS_ROOT=${BUILDS_ROOT:-$HERE/mkosi.output}

builds_id() { echo "${1//,/-}_$2"; }
builds_dir() { echo "$BUILDS_ROOT/$1/$2"; }
builds_groups_of() { local g=${1%%_*}; echo "${g//-/,}"; } # BUILD -> groups
builds_version_of() { echo "${1#*_}"; }                     # BUILD -> version

builds_all() { # [VARIANT]
	local v d
	for v in ${1:-network usb}; do
		for d in "$BUILDS_ROOT/$v"/*_*/; do
			[[ -f $d/build.json ]] && echo "$v/$(basename "$d")"
		done | LC_ALL=C sort
	done
	return 0
}

builds_find() { # BUILD or VARIANT/BUILD
	local hits
	if [[ $1 == */* ]]; then
		[[ -f $BUILDS_ROOT/$1/build.json ]] || die "no build $1 (./build.sh list)"
		echo "$1"
		return
	fi
	mapfile -t hits < <(builds_all | awk -F/ -v b="$1" '$2 == b')
	((${#hits[@]} == 1)) || die "$( ((${#hits[@]})) && echo "build $1 exists for several variants: say network/$1 or usb/$1" || echo "no build $1 (./build.sh list)")"
	echo "${hits[0]}"
}

# Newest by version (the build time), not by file time.
builds_newest() { # VARIANT [GROUPS]
	local want=${2:-}
	builds_all "$1" | while IFS=/ read -r _ b; do
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

builds_list() { # [VARIANT]
	local vb v b d rel
	printf '%-8s %-44s %-17s %-11s %5s %7s  %s\n' VARIANT BUILD BUILT SNAPSHOT PKGS SIZE "LAST RELEASE"
	while IFS= read -r vb; do
		v=${vb%%/*} b=${vb#*/} d=$(builds_dir "$v" "$b")
		rel=$(builds_last_release "$d")
		printf '%-8s %-44s %-17s %-11s %5s %7s  %s\n' "$v" "$b" \
			"$(builds_info "$d" finished | cut -c1-16 | tr T ' ')" "$(builds_info "$d" snapshot)" \
			"$(builds_info "$d" packages)" "$(du -sh "$d" 2>/dev/null | cut -f1)" "${rel:--}"
	done < <(builds_all "${1:-}")
	# Directories without build.json: failed or running builds.
	find "$BUILDS_ROOT"/{network,usb} -mindepth 1 -maxdepth 1 -type d ! -exec test -f '{}/build.json' \; -printf '%P (incomplete: no build.json)\n' 2>/dev/null |
		sed 's/^/         /'
	return 0
}

builds_show() { # VARIANT BUILD
	local d
	d=$(builds_dir "$1" "$2")
	python3 -I - "$d" <<-'EOF'
		import json, sys, glob
		d = sys.argv[1]
		info = json.load(open(d + "/build.json"))
		for k, v in info.items():
		    print(f"{k:12} {','.join(map(str, v)) if isinstance(v, list) else v}")
		for m in glob.glob(d + "/*.manifest"):
		    pk = json.load(open(m))["packages"]
		    print(f"\npackages ({len(pk)}):")
		    for p in sorted(pk, key=lambda p: p["name"]):
		        print(f"  {p['name']:40} {p['version']}")
	EOF
	[[ -f $d/released.log ]] && { echo; echo "released:"; sed 's/^/  /' "$d/released.log"; }
	return 0
}

builds_diff() { # VARIANT/BUILD VARIANT/BUILD
	python3 -I - "$BUILDS_ROOT/$1" "$BUILDS_ROOT/$2" <<-'EOF'
		import json, sys, glob
		def pk(d):
		    m = glob.glob(d + "/*.manifest")
		    if not m: sys.exit(f"no manifest in {d}")
		    return {p["name"]: p["version"] for p in json.load(open(m[0]))["packages"]}
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
	local keep=$1 yes=$2 v g b d last=() del=() n
	# The build each target got last stays, whatever its age.
	for v in network usb; do
		while IFS= read -r line; do last+=("$v/${line##* }"); done < <(
			for d in "$BUILDS_ROOT/$v"/*_*/; do
				[[ -f $d/released.log ]] || continue
				awk -v b="$(basename "$d")" '{ print $1, $2, b }' "$d/released.log"
			done | sort -k2,2 -k1,1r | awk '!seen[$2]++ { print $3 }')
	done
	for v in network usb; do
		for g in $(builds_all "$v" | while IFS=/ read -r _ b; do builds_groups_of "$b"; done | sort -u); do
			n=0
			while IFS= read -r b; do
				n=$((n + 1))
				((n > keep)) || continue
				[[ " ${last[*]} " == *" $v/$b "* ]] && { log "keeping $v/$b (last release to a target)"; continue; }
				del+=("$v/$b")
			done < <(builds_all "$v" | while IFS=/ read -r _ b; do
				[[ $(builds_groups_of "$b") == "$g" ]] && echo "$(builds_version_of "$b") $b"
			done | sort -r | awk '{ print $2 }')
		done
		# Leftovers of failed builds (no build.json), except one still being written.
		while IFS= read -r d; do
			[[ -n $(find "$d" -mmin -120 -print -quit) ]] || del+=("$v/$(basename "$d")")
		done < <(find "$BUILDS_ROOT/$v" -mindepth 1 -maxdepth 1 -type d ! -exec test -f '{}/build.json' \; -print 2>/dev/null)
	done
	((${#del[@]})) || { log "nothing to prune (keeping $keep per variant and group set)"; return 0; }
	printf '  delete %s (%s)\n' $(for b in "${del[@]}"; do echo "$b" "$(du -sh "$BUILDS_ROOT/$b" | cut -f1)"; done)
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
		import json, sys, glob, os
		d, pairs = sys.argv[1], sys.argv[2:]
		info = {}
		for p in pairs:
		    k, _, v = p.partition("=")
		    info[k] = [x for x in v.split(",") if x] if k in ("groups", "netroot") else v
		m = glob.glob(d + "/*.manifest")
		info["packages"] = len(json.load(open(m[0]))["packages"]) if m else 0
		for k, pat in (("uki_bytes", "*.efi"), ("image_bytes", "*.raw.zst")):
		    f = [x for x in glob.glob(d + "/" + pat) if not os.path.islink(x)]
		    info[k] = sum(os.path.getsize(x) for x in f)
		with open(d + "/build.json", "w") as f:
		    json.dump(info, f, indent=2)
		    f.write("\n")
	EOF
}
