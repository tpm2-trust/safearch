# The builds on the build host. Sourced by build.sh, release.sh, burn.sh,
# test-vm.sh and tests/vm.sh; expects die() and log(). Needs python3 (JSON).
#
# Layout: one directory per build (build.sh composes it from one mkosi run
# per combination, lib/compose.sh); the same parts serve a stick and the
# network:
#   mkosi.output/combined_<version>/
#     boot.efi              the signed UKI (safespace.root.<name>=<hash> per combination)
#     systemd-boot.efi      the signed systemd-boot (\EFI\BOOT\BOOTX64.EFI on a stick)
#     layout.sfdisk         a stick's partition table (lib/stick.sh)
#     root-<name>.img       per combination: the root partition (erofs, dm-verity data)
#     root-<name>.verity    its dm-verity hash tree
#     roothash-<name>       its root hash (also on the UKI's signed command line)
#     manifest-<name>.json  its packages
#     vnc-password-<name>   xfce4-headless-vnc: the generated VNC password (0600)
#     build.json            what, when, from what (builds_write_info)
#     released.log          "<time> <target>" per push (release.sh)
# <version> is the build time (YYYYMMDD-HHMM[SS]). The directory name is "the
# build": what list, release.sh --build and the servers show.
#
#   builds_all                    the complete builds, oldest first
#   builds_dir BUILD              its directory
#   builds_find BUILD             the build, or die
#   builds_newest                 the newest complete build
#   builds_info DIR KEY           a value from build.json
#   builds_list                   the overview table
#   builds_show BUILD             details and package lists
#   builds_diff A B               package differences of two builds, per combination
#   builds_prune KEEP YES         delete all but the newest KEEP
#   builds_finalize DIR VERSION   one combination's mkosi output -> its parts
#                                 (boot.efi, root.img, root.verity, roothash,
#                                 manifest.json, systemd-boot.efi,
#                                 layout.sfdisk, systemd-stub.efi), which
#                                 lib/compose.sh turns into the build
# A build is complete once build.json exists (written after a successful build).

BUILDS_ROOT=${BUILDS_ROOT:-$HERE/mkosi.output}
BUILDS_IMAGE_ID=safespace-arch

builds_dir() { echo "$BUILDS_ROOT/$1"; }
builds_version_of() { echo "${1#combined_}"; } # BUILD -> version

builds_all() {
	local d
	for d in "$BUILDS_ROOT"/combined_*/; do
		[[ -f $d/build.json ]] && basename "$d"
	done | LC_ALL=C sort
	return 0
}

builds_find() { # BUILD
	[[ $1 =~ ^combined_[0-9][0-9A-Za-z._-]*$ && -f $BUILDS_ROOT/$1/build.json ]] || die "no build $1 (./build.sh list)"
	echo "$1"
}

# The version is the build time: the names sort by it.
builds_newest() { builds_all | tail -n 1; }

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
	printf '%-28s %-17s %-11s %5s %7s  %s\n' BUILD BUILT SNAPSHOT PKGS SIZE "LAST RELEASE"
	while IFS= read -r b; do
		d=$(builds_dir "$b")
		rel=$(builds_last_release "$d")
		printf '%-28s %-17s %-11s %5s %7s  %s\n' "$b" \
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
		for c in info.get("combinations", []):
		    n = c.split(":")[0]
		    pk = json.load(open(f"{d}/manifest-{n}.json"))["packages"]
		    print(f"\n{n} ({c.split(':')[1].replace('+', ',')}): {len(pk)} packages")
		    for p in sorted(pk, key=lambda p: p["name"]):
		        print(f"  {p['name']:40} {p['version']}")
	EOF
	[[ -f $d/released.log ]] && { echo; echo "released:"; sed 's/^/  /' "$d/released.log"; }
	return 0
}

builds_diff() { # BUILD BUILD
	python3 -I - "$BUILDS_ROOT/$1" "$BUILDS_ROOT/$2" <<-'EOF'
		import json, sys, os
		def combos(d):
		    return [c.split(":")[0] for c in json.load(open(d + "/build.json")).get("combinations", [])]
		def pk(d, c):
		    m = f"{d}/manifest-{c}.json"
		    return {p["name"]: p["version"] for p in json.load(open(m))["packages"]} if os.path.exists(m) else None
		da, db = sys.argv[1], sys.argv[2]
		ca, cb = combos(da), combos(db)
		for c in ca + [c for c in cb if c not in ca]:
		    a, b = pk(da, c), pk(db, c)
		    if a is None: print(f"{c}: only in the second build"); continue
		    if b is None: print(f"{c}: only in the first build"); continue
		    print(f"{c}:")
		    for n in sorted(set(a) | set(b)):
		        if n not in a: print(f"  + {n:40} {b[n]}")
		        elif n not in b: print(f"  - {n:40} {a[n]}")
		        elif a[n] != b[n]: print(f"  ~ {n:40} {a[n]} -> {b[n]}")
		    same = sum(1 for n in a if b.get(n) == a[n])
		    print(f"  ({same} packages unchanged)")
	EOF
}

builds_prune() { # KEEP YES
	local keep=$1 yes=$2 b d last=() del=() n=0
	# The build each target got last stays, whatever its age.
	while IFS= read -r b; do last+=("$b"); done < <(
		for d in "$BUILDS_ROOT"/combined_*/; do
			[[ -f $d/released.log ]] || continue
			awk -v b="$(basename "$d")" '{ print $1, $2, b }' "$d/released.log"
		done | sort -k2,2 -k1,1r | awk '!seen[$2]++ { print $3 }')
	while IFS= read -r b; do
		n=$((n + 1))
		((n > keep)) || continue
		[[ " ${last[*]} " == *" $b "* ]] && { log "keeping $b (last release to a target)"; continue; }
		del+=("$b")
	done < <(builds_all | sort -r)
	# Leftovers of failed builds (no build.json), except one still being written.
	while IFS= read -r d; do
		[[ -n $(find "$d" -mmin -120 -print -quit) ]] || del+=("$(basename "$d")")
	done < <(find "$BUILDS_ROOT" -mindepth 1 -maxdepth 1 -type d ! -exec test -f '{}/build.json' \; -print 2>/dev/null)
	((${#del[@]})) || { log "nothing to prune (keeping $keep)"; return 0; }
	for b in "${del[@]}"; do printf '  delete %s (%s)\n' "$b" "$(du -sh "$BUILDS_ROOT/$b" | cut -f1)"; done
	if ((!yes)); then
		read -rp "Delete these ${#del[@]} build(s)? Type YES: " answer
		[[ $answer == YES ]] || die "aborted"
	fi
	for b in "${del[@]}"; do rm -rf -- "${BUILDS_ROOT:?}/$b"; done
	log "deleted ${#del[@]} build(s)"
}

# build.json for a finished build (build.sh, as root, after mkosi succeeded).
builds_write_info() { # DIR, then KEY=VALUE pairs (VALUE with commas = a list for combinations/netroot)
	local d=$1; shift
	python3 -I - "$d" "$@" <<-'EOF'
		import json, sys, os, glob
		d, pairs = sys.argv[1], sys.argv[2:]
		info = {}
		for p in pairs:
		    k, _, v = p.partition("=")
		    info[k] = [x for x in v.split(",") if x] if k in ("netroot", "combinations") else v
		info["packages"] = sum(len(json.load(open(m))["packages"]) for m in sorted(glob.glob(d + "/manifest-*.json")))
		info["uki_bytes"] = os.path.getsize(d + "/boot.efi") if os.path.exists(d + "/boot.efi") else 0
		info["root_bytes"] = sum(os.path.getsize(f) for f in glob.glob(d + "/root*.img"))
		with open(d + "/build.json", "w") as f:
		    json.dump(info, f, indent=2)
		    f.write("\n")
	EOF
}

# mkosi writes <ImageId>_<version>.{efi,root.raw,root-verity.raw,roothash,
# manifest,raw,...}; keep only one combination's parts (see the top), under
# short names. The
# partition table and the signed systemd-boot come out of the whole disk image
# first; then the image and mkosi's separate initrd copy go: nothing is kept
# or shipped twice.
# Firmware is chosen by package (mkosi.conf, Packages=): the meta package or any
# other split package pulled back in as a dependency fails the build, instead of
# being downloaded, installed and then filtered.
BUILDS_FIRMWARE_ALLOWED=(linux-firmware-intel linux-firmware-amdgpu linux-firmware-realtek linux-firmware-whence)
builds_check_firmware() { # MANIFEST
	local extra
	extra=$(python3 -I -c '
import json, sys
allowed = set(sys.argv[2:])
names = [p["name"] for p in json.load(open(sys.argv[1]))["packages"]]
print(" ".join(n for n in names if (n == "linux-firmware" or n.startswith("linux-firmware-")) and n not in allowed))' \
		"$1" "${BUILDS_FIRMWARE_ALLOWED[@]}") || die "builds_check_firmware: cannot read $1"
	[[ -z $extra ]] || die "firmware packages outside mkosi.conf's selection were installed: $extra (which package depends on them: pacman -Qi)"
}

builds_finalize() { # DIR VERSION
	local d=$1 b f off
	b=$d/${BUILDS_IMAGE_ID}_$2
	for f in efi:boot.efi root.raw:root.img root-verity.raw:root.verity roothash:roothash manifest:manifest.json; do
		[[ -f $b.${f%%:*} ]] || die "builds_finalize: mkosi wrote no $(basename "$b").${f%%:*}"
		mv -f "$b.${f%%:*}" "$d/${f#*:}"
	done
	[[ -f $b.vnc-password ]] && mv -f "$b.vnc-password" "$d/vnc-password"
	builds_check_firmware "$d/manifest.json"
	[[ -f $b.systemd-stub ]] || die "builds_finalize: mkosi.finalize kept no $(basename "$b").systemd-stub"
	mv -f "$b.systemd-stub" "$d/systemd-stub.efi"
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
