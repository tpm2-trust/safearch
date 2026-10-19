# Combinations: several group sets in one build, one signed UKI for all.
# Sourced by build.sh (--combined); expects die(), log() and lib/groups.sh.
#
#   combos_load FILE            read combinations.conf into COMBO_NAMES/COMBO_GROUPS
#   compose_build DEST DIR...   one build directory per combination (same
#                               order as COMBO_NAMES; the first is "base")
#                               -> the combined build in DEST
#   compose_layout OUT BASE_LAYOUT DIR   the stick's partition table: the ESP of
#                               the base layout, then one root/verity pair per
#                               combination (root-<name>.img/.verity in DIR)
#
# The combined build:
#   boot.efi                 one UKI: kernel, initrd and microcode of the base
#                            build, the command line with
#                            safespace.root.<name>=<root hash> per combination
#                            (instead of roothash=), signed with the db key and
#                            with signed expected PCRs, from the image's stub
#   systemd-boot.efi, layout.sfdisk
#   root-<name>.img, root-<name>.verity, roothash-<name>, manifest-<name>.json
#   vnc-password-<name>      (combinations with remotedesktop)
# The initrd picks the combination at boot (mkosi.initrd.conf/.../select).

COMBO_NAMES=() COMBO_GROUPS=()

combos_load() { # FILE
	local line name groups
	COMBO_NAMES=() COMBO_GROUPS=()
	[[ -f $1 ]] || die "no $1"
	while IFS= read -r line; do
		[[ $line =~ ^[[:space:]]*(#|$) ]] && continue
		[[ $line =~ ^([a-z][a-z0-9-]{0,23})=([A-Za-z,[:space:]]+)$ ]] || die "$1: bad line: $line"
		name=${BASH_REMATCH[1]} groups=${BASH_REMATCH[2]}
		[[ " ${COMBO_NAMES[*]} " != *" $name "* ]] || die "$1: $name twice"
		groups_parse "$groups"
		COMBO_NAMES+=("$name")
		COMBO_GROUPS+=("$(IFS=,; echo "${SAFESPACE_GROUPS[*]}")")
	done <"$1"
	[[ ${COMBO_NAMES[0]:-} == base && ${COMBO_GROUPS[0]} == base ]] ||
		die "$1: the first combination must be base=base (what a machine boots without a selection)"
	((${#COMBO_NAMES[@]} >= 2)) || die "$1: at least two combinations"
}

uki_section() { objcopy -O binary --only-section="$2" "$1" /dev/stdout 2>/dev/null | tr -d '\0'; }

compose_layout() { # OUT BASE_LAYOUT DIR
	local out=$1 base=$2 dir=$3 h esp parts="" n part file start end size root half type name
	h=$(sed -n '/^label:/p; /^label-id:/p; /^unit:/p; /^first-lba:/p' "$base")
	esp=$(grep -i 'type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B' "$base") || die "$base: no ESP"
	# Partitions start on 1 MiB boundaries after the ESP.
	end=$(awk -F'[=,]' '{ gsub(/ /, ""); print $2 + $4 }' <<<"$esp")
	align() { echo $((($1 + 2047) / 2048 * 2048)); }
	uuid() { sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/' <<<"$1" | tr a-f A-F; }
	for n in "${COMBO_NAMES[@]}"; do
		root=$(tr -d "[:space:]" <"$dir/roothash-$n")
		for part in root verity; do
			if [[ $part == root ]]; then
				file=root-$n.img type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709 name=root-$n half=${root:0:32}
			else
				file=root-$n.verity type=2C7357ED-EBD2-46D9-AEC1-23D437EC2BF5 name=root-$n-verity half=${root:32}
			fi
			start=$(align "$end")
			size=$((($(stat -c %s "$dir/$file") + 511) / 512))
			parts+=$(printf 'start=%12d, size=%12d, type=%s, uuid=%s, name="%s", attrs="GUID:60"' \
				"$start" "$size" "$type" "$(uuid "$half")" "$name")$'\n'
			end=$((start + size))
		done
	done
	printf '%s\nlast-lba: %d\nsector-size: 512\n\n%s\n%s' "$h" $(($(align "$end") + 2047)) "$esp" "$parts" >"$out"
}

# The common UKI, built as mkosi builds one (ukify with the same options), from
# the base build's sections and the image's stub.
compose_uki() { # OUT BASE_UKI STUB CMDLINE
	local out=$1 uki=$2 stub=$3 t
	t=$(mktemp -d)
	for s in linux initrd ucode osrel; do
		objcopy -O binary --only-section=".$s" "$uki" "$t/$s" || { rm -rf "$t"; die "no .$s in $uki"; }
	done
	printf '%s\0' "$4" >"$t/cmdline"
	ukify build --efi-arch x64 --stub "$stub" --output "$out" \
		--linux "$t/linux" --initrd "$t/initrd" --microcode "$t/ucode" \
		--os-release "@$t/osrel" --uname "$(uki_section "$uki" .uname)" --cmdline "@$t/cmdline" \
		--no-sign-kernel --signtool systemd-sbsign \
		--secureboot-private-key "$KEYS_SB_DIR/db/db.key" --secureboot-certificate "$KEYS_SB_DIR/db/db.pem" \
		--pcr-banks sha256 --pcr-certificate "$KEYS_PCR_CERT" --pcr-private-key "$KEYS_PCR_KEY" \
		--sign-initrd-pcrs >"$t/ukify.log" 2>&1 || { cat "$t/ukify.log" >&2; rm -rf "$t"; die "ukify failed"; }
	rm -rf "$t"
}

compose_build() { # DEST DIR...
	local dest=$1 base=$2 i n d cmdline uname
	shift
	(($# == ${#COMBO_NAMES[@]})) || die "compose_build: ${#COMBO_NAMES[@]} combinations, $# builds"
	mkdir -p "$dest"
	[[ -f $base/systemd-stub.efi ]] || die "$base has no systemd-stub.efi (built before mkosi.finalize kept it?)"
	# All combinations must run the base build's kernel.
	uname=$(uki_section "$base/boot.efi" .uname)
	for d in "$@"; do
		[[ $(uki_section "$d/boot.efi" .uname) == "$uname" ]] || die "$d has another kernel than $base ($uname)"
	done
	# The command line: base's, with one root hash per combination instead of roothash=.
	cmdline=$(uki_section "$base/boot.efi" .cmdline | tr ' ' '\n' | grep -v '^roothash=' | grep . | tr '\n' ' ')
	i=0
	for d in "$@"; do
		n=${COMBO_NAMES[i]}
		h=$(tr -d "[:space:]" <"$d/roothash")
		[[ $h =~ ^[0-9a-f]{64}$ ]] || die "$d/roothash is not a root hash"
		cmdline+="safespace.root.$n=$h "
		mv "$d/root.img" "$dest/root-$n.img"
		mv "$d/root.verity" "$dest/root-$n.verity"
		echo "$h" >"$dest/roothash-$n"
		mv "$d/manifest.json" "$dest/manifest-$n.json"
		[[ -f $d/vnc-password ]] && mv "$d/vnc-password" "$dest/vnc-password-$n"
		i=$((i + 1))
	done
	cmdline=${cmdline% }
	log "common UKI: $cmdline"
	compose_uki "$dest/boot.efi" "$base/boot.efi" "$base/systemd-stub.efi" "$cmdline"
	cp "$base/systemd-boot.efi" "$dest/systemd-boot.efi"
	compose_layout "$dest/layout.sfdisk" "$base/layout.sfdisk" "$dest"
	chmod 0644 "$dest"/{boot.efi,systemd-boot.efi,layout.sfdisk} "$dest"/root-* "$dest"/roothash-* "$dest"/manifest-*
}
