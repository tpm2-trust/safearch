# The layers of a build: every group built once, as a layer on the one below
# it (PLAN.md; SECURITY.md, "Layers"). Sourced by build.sh and tests/run.sh;
# expects die(), log(), $HERE, and the combinations and layers of lib/compose.sh
# (COMBO_NAMES, COMBO_GROUPS, LAYER_NAMES, LAYER_PARENT).
#
#   layers_chain LAYER           the layers up to LAYER, bottom first ("base docker")
#   layers_combination LAYER     the combination LAYER's tree is built as: the one
#                                whose top it is, else the first that has it (the
#                                combination's own files - its name, its groups -
#                                are in its top layer)
#   layers_profiles LAYER        mkosi's --profile= for the groups of the chain
#   layers_packages LOWER FULL   FULL's manifest keeps every package of LOWER's,
#                                at its version: a layer only adds
#   layers_diff LOWER FULL OUT   OUT: the layer - FULL's paths that are new or
#                                differ from LOWER (lib/layertree.py); none of
#                                LOWER's deleted, the kernel not touched
#   layers_prove FULL TOP...     the layers stacked as the initrd stacks them (top
#                                first, the base tree last) are FULL, file for file
#   layers_image TREE DIR WORKERS  DIR/root.img (erofs, zstd 6 as mkosi.repart),
#                                root.verity, roothash (dm-verity)

layers_chain() { # LAYER
	local l=$1 chain=$1
	while [[ -n ${LAYER_PARENT[$l]} ]]; do
		l=${LAYER_PARENT[$l]}
		chain="$l $chain"
	done
	echo "$chain"
}

layers_combination() { # LAYER
	local chain i
	chain=$(layers_chain "$1")
	for i in "${!COMBO_NAMES[@]}"; do
		[[ ${COMBO_GROUPS[i]} == "${chain// /,}" ]] && { echo "${COMBO_NAMES[i]}"; return; }
	done
	for i in "${!COMBO_NAMES[@]}"; do
		[[ ,${COMBO_GROUPS[i]}, == *",$1,"* ]] && { echo "${COMBO_NAMES[i]}"; return; }
	done
	die "layer $1 is in no combination"
}

layers_profiles() { # LAYER
	local g
	for g in $(layers_chain "$1"); do
		[[ $g == base ]] || echo "--profile=$g"
	done
}

layers_packages() { # LOWER_MANIFEST FULL_MANIFEST
	python3 -I - "$1" "$2" <<-'PY' || die "a layer changes the packages below it ($2): build with -f, so that every layer is installed from the same package metadata"
		import json, sys
		load = lambda f: {p["name"]: p["version"] for p in json.load(open(f))["packages"]}
		lower, full = load(sys.argv[1]), load(sys.argv[2])
		bad = [f"{n} {v} -> {full.get(n, 'removed')}" for n, v in sorted(lower.items()) if full.get(n) != v]
		for b in bad[:20]:
		    print("  " + b, file=sys.stderr)
		sys.exit(1 if bad else 0)
	PY
}

layers_diff() { # LOWER FULL OUT
	local list=$3.list rc=0 name
	name=$(basename "$(dirname "$3")")
	install -d "$3"
	python3 -I "$HERE/lib/layertree.py" diff "$1" "$2" "$list" || rc=$?
	case $rc in
		0) ;;
		2) die "the layer $name deletes paths of the layer below (overlayfs would show them): a layer only adds" ;;
		3) die "the layer $name changes the kernel's modules: one kernel, the base's, for every combination" ;;
		*) die "comparing the layer $name with the one below failed" ;;
	esac
	# Numeric owners, every xattr (file capabilities, ACLs): the proof compares them.
	tar -C "$2" --numeric-owner --xattrs --xattrs-include='*' --null --no-recursion -T "$list" -cf - |
		tar -C "$3" --numeric-owner --same-owner --same-permissions --xattrs --xattrs-include='*' -xf - ||
		die "copying the layer $name failed"
	rm -f "$list"
}

layers_prove() { # FULL TOP... (the base's tree last)
	local full=$1 m rc=0; shift
	m=$(mktemp -d)
	mount -t overlay overlay -o "$SETTINGS_OVERLAY,lowerdir=$(IFS=:; echo "$*")" "$m" ||
		{ rmdir "$m"; die "stacking the layers ($*) failed"; }
	python3 -I "$HERE/lib/layertree.py" compare "$m" "$full" || rc=$?
	umount "$m" && rmdir "$m"
	((rc == 0)) || die "the layers stacked are not $(basename "$full") (above): the build is wrong, nothing is shipped"
}

layers_image() { # TREE DIR WORKERS
	local tree=$1 dir=$2 h
	install -d "$dir"
	mkfs.erofs -zzstd,6 --workers="$3" --exclude-regex='^(var|efi|boot)/.' "$dir/root.img" "$tree" >/dev/null ||
		die "mkfs.erofs failed for $(basename "$tree")"
	h=$(veritysetup format "$dir/root.img" "$dir/root.verity" | sed -n 's/^Root hash:[[:space:]]*//p')
	[[ $h =~ ^[0-9a-f]{64}$ ]] || die "veritysetup format failed for $(basename "$tree")"
	printf '%s\n' "$h" >"$dir/roothash"
}
