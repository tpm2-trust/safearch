# Combinations: the group sets of safespace.conf's COMBINATIONS, one root each, one signed
# UKI for all. Sourced by build.sh; expects die(), log(), lib/groups.sh and
# lib/verify.sh.
#
#   combos_load LIST            COMBINATIONS of safespace.conf ("name=groups ...")
#                               into COMBO_NAMES/COMBO_GROUPS (base first: the
#                               combination's chain of layers, bottom first), and
#                               the layers: LAYER_NAMES (each after the one it
#                               lies on), LAYER_PARENT[layer]
#                               (COMBO_NAMES[0]: the default, booted without a selection)
#   compose_build DEST PARTS    the parts of build.sh (PARTS/base: the base's
#                               finalized image; PARTS/<layer>: a layer's root.img,
#                               root.verity, roothash; PARTS/combo-<name>: a
#                               combination's manifest) -> the build in DEST
#   compose_check DEST DB_CERT  the composed build is what it must be (see there)
#   compose_layout OUT FIRST_LAYOUT DIR   the stick's partition table: the ESP of
#                               the base's layout, then one root/verity pair per
#                               layer (root-<layer>.img/.verity in DIR)
#
# The build:
#   boot.efi                 one UKI: kernel, initrd and microcode of the base,
#                            the command line with safespace.layer.<layer>=<root
#                            hash> per layer and safespace.root.<name>=<layer>,...
#                            per combination, bottom first (instead of
#                            roothash=, root=), signed with the db key and
#                            with signed expected PCRs, from the image's stub;
#                            the initrd carries the identity key's public part
#                            (usr/local/lib/safespace/identity.pem), the .pcrsig
#                            its signature for the phase enter-initrd only
#   systemd-boot.efi, layout.sfdisk
#   root-<layer>.img, root-<layer>.verity, roothash-<layer>; manifest-<name>.json
#   vnc-password-<name>      (combinations with xfce4-headless-vnc)
# The initrd picks the combination at boot (mkosi.initrd.conf/.../select).

COMBO_NAMES=() COMBO_GROUPS=() LAYER_NAMES=()
declare -gA LAYER_PARENT=()

# A group is a layer, built once on exactly one layer below it (base on none):
# combinations are chains, never free combinations of layers. A group that lies
# on another layer in a second combination is refused, and two combinations of
# the same chain (they would be the same root).
combos_load() { # LIST
	local c name groups list g parent
	COMBO_NAMES=() COMBO_GROUPS=() LAYER_NAMES=()
	LAYER_PARENT=()
	read -ra list <<<"$1"
	for c in ${list[@]+"${list[@]}"}; do
		[[ $c =~ ^([a-z][a-z0-9-]{0,23})=([A-Za-z0-9,-]+)$ ]] || die "COMBINATIONS: bad combination '$c' (name=group,group)"
		name=${BASH_REMATCH[1]} groups=${BASH_REMATCH[2]}
		[[ " ${COMBO_NAMES[*]} " != *" $name "* ]] || die "COMBINATIONS: $name twice"
		groups_parse "$groups"
		groups=$(IFS=,; echo "${SAFESPACE_GROUPS[*]}")
		for c in "${!COMBO_GROUPS[@]}"; do
			[[ ${COMBO_GROUPS[c]} != "$groups" ]] || die "COMBINATIONS: $name is ${COMBO_NAMES[c]} again ($groups): one combination per chain"
		done
		parent=""
		for g in "${SAFESPACE_GROUPS[@]}"; do
			if [[ -v LAYER_PARENT[$g] ]]; then
				[[ ${LAYER_PARENT[$g]} == "$parent" ]] ||
					die "COMBINATIONS: $g lies on ${LAYER_PARENT[$g]} in one combination, on $parent in $name: a layer is built once, on one layer (name the groups in the same order)"
			else
				LAYER_PARENT[$g]=$parent
				LAYER_NAMES+=("$g")
			fi
			parent=$g
		done
		COMBO_NAMES+=("$name")
		COMBO_GROUPS+=("$groups")
	done
	((${#COMBO_NAMES[@]})) || die "COMBINATIONS: no combination (safespace.conf)"
}

compose_layout() { # OUT FIRST_LAYOUT DIR
	local out=$1 base=$2 dir=$3 h esp parts="" n part file start end size root half type name
	h=$(sed -n '/^label:/p; /^label-id:/p; /^unit:/p; /^first-lba:/p' "$base")
	esp=$(grep -i "type=$GPT_ESP" "$base") || die "$base: no ESP"
	# Partitions start on 1 MiB boundaries after the ESP.
	end=$(awk -F'[=,]' '{ gsub(/ /, ""); print $2 + $4 }' <<<"$esp")
	align() { echo $((($1 + 2047) / 2048 * 2048)); }
	for n in "${LAYER_NAMES[@]}"; do
		root=$(tr -d "[:space:]" <"$dir/roothash-$n")
		for part in root verity; do
			if [[ $part == root ]]; then
				file=root-$n.img type=$GPT_ROOT name=root-$n half=${root:0:32}
			else
				file=root-$n.verity type=$GPT_VERITY name=root-$n-verity half=${root:32}
			fi
			start=$(align "$end")
			size=$((($(stat -c %s "$dir/$file") + 511) / 512))
			parts+=$(printf 'start=%12d, size=%12d, type=%s, uuid=%s, name="%s", attrs="GUID:60"' \
				"$start" "$size" "$type" "$(layout_uuid "$half" | tr a-f A-F)" "$name")$'\n'
			end=$((start + size))
		done
	done
	printf '%s\nlast-lba: %d\nsector-size: 512\n\n%s\n%s' "$h" $(($(align "$end") + 2047)) "$esp" "$parts" >"$out"
}

# The common UKI, built as mkosi builds one (ukify with the same options), from
# the first combination's sections and the image's stub.
compose_uki() { # OUT FIRST_UKI STUB CMDLINE
	local out=$1 uki=$2 stub=$3 t v
	t=$(mktemp -d)
	for s in linux initrd ucode osrel; do
		objcopy -O binary --only-section=".$s" "$uki" "$t/$s" || { rm -rf "$t"; die "no .$s in $uki"; }
	done
	printf '%s\0' "$4" >"$t/cmdline"
	# The UKI serves every combination: its name (systemd-boot's entry) must not be
	# the first one's.
	tr -d '\0' <"$t/osrel" | sed -E '/^(PRETTY_NAME|VARIANT|VARIANT_ID)=/d' >"$t/osrel.all"
	v=$(sed -n 's/^IMAGE_VERSION="\{0,1\}\([0-9-]*\)"\{0,1\}$/\1/p' "$t/osrel.all")
	[[ $v =~ ^[0-9]{8}-[0-9]{4,6}$ ]] || { rm -rf "$t"; die "no IMAGE_VERSION in the .osrel of $uki"; }
	printf 'PRETTY_NAME="safespace %s"\n' "$v" >>"$t/osrel.all"
	mv "$t/osrel.all" "$t/osrel"
	# The public parts of the identity key (the machine-id's policy) and of the
	# PCR key (the CA's slot 0: aSSH takes PCR 11 signed by it), for the
	# identity's creation in the initrd (mkosi.initrd.conf/.../identity): appended
	# as a cpio of its own, the kernel unpacks every archive of the initrd in turn.
	# (ukify adds no .pcrpkey section, so systemd-stub hands over no key.)
	install -d "$t/id/usr/local/lib/safespace"
	openssl x509 -in "$KEYS_ID_CERT" -pubkey -noout >"$t/id/usr/local/lib/safespace/identity.pem" ||
		{ rm -rf "$t"; die "cannot read the identity key's certificate $KEYS_ID_CERT"; }
	openssl x509 -in "$KEYS_PCR_CERT" -pubkey -noout >"$t/id/usr/local/lib/safespace/pcr.pem" ||
		{ rm -rf "$t"; die "cannot read the PCR key's certificate $KEYS_PCR_CERT"; }
	(cd "$t/id" && find usr | sort | cpio -o -H newc --owner=0:0 --reproducible --quiet) >>"$t/initrd" ||
		{ rm -rf "$t"; die "cannot append the identity key to the initrd"; }
	# Two PCR signing keys: mkosi's for every phase, the identity key for
	# enter-initrd only. Both banks:
	# SHA-1 for a TPM whose firmware activates nothing else (T450s), used there
	# only where safespace tpm sha1 allows it (initrd identity); a SHA-256 TPM
	# seals to SHA-256, which no SHA-1 signature satisfies.
	ukify build --efi-arch x64 --stub "$stub" --output "$out" \
		--linux "$t/linux" --initrd "$t/initrd" --microcode "$t/ucode" \
		--os-release "@$t/osrel" --uname "$(uki_section "$uki" .uname)" --cmdline "@$t/cmdline" \
		--no-sign-kernel --signtool systemd-sbsign \
		--secureboot-private-key "$KEYS_SB_DIR/db/db.key" --secureboot-certificate "$KEYS_SB_DIR/db/db.pem" \
		--pcr-banks sha1,sha256 \
		--pcr-certificate "$KEYS_PCR_CERT" --pcr-private-key "$KEYS_PCR_KEY" \
		--phases "enter-initrd enter-initrd:leave-initrd enter-initrd:leave-initrd:sysinit enter-initrd:leave-initrd:sysinit:ready" \
		--pcr-certificate "$KEYS_ID_CERT" --pcr-private-key "$KEYS_ID_KEY" --phases enter-initrd \
		--sign-initrd-pcrs >"$t/ukify.log" 2>&1 || { cat "$t/ukify.log" >&2; rm -rf "$t"; die "ukify failed"; }
	rm -rf "$t"
}

compose_build() { # DEST PARTS
	local dest=$1 parts=$2 base=$2/base i n l d h cmdline
	mkdir -p "$dest"
	[[ -f $base/systemd-stub.efi ]] || die "$base has no systemd-stub.efi (mkosi.finalize keeps it)"
	# The command line: the base image's, without its root (roothash=, root=,
	# rootfstype=: the initrd stacks the chosen combination's layers itself),
	# with one root hash per layer and one chain of layers per combination.
	cmdline=$(uki_section "$base/boot.efi" .cmdline | tr ' ' '\n' | grep -Ev '^(roothash|root|rootfstype)=' | grep . | tr '\n' ' ')
	for l in "${LAYER_NAMES[@]}"; do
		[[ $l == base ]] && d=$base || d=$parts/$l
		h=$(tr -d "[:space:]" <"$d/roothash")
		[[ $h =~ ^[0-9a-f]{64}$ ]] || die "$d/roothash is not a root hash"
		cmdline+="safespace.layer.$l=$h "
		mv "$d/root.img" "$dest/root-$l.img"
		mv "$d/root.verity" "$dest/root-$l.verity"
		echo "$h" >"$dest/roothash-$l"
	done
	for i in "${!COMBO_NAMES[@]}"; do
		n=${COMBO_NAMES[i]}
		cmdline+="safespace.root.$n=${COMBO_GROUPS[i]} "
		mv "$parts/combo-$n/manifest.json" "$dest/manifest-$n.json"
		[[ -f $parts/combo-$n/vnc-password ]] && mv "$parts/combo-$n/vnc-password" "$dest/vnc-password-$n"
	done
	cmdline=${cmdline% }
	log "common UKI: $cmdline"
	compose_uki "$dest/boot.efi" "$base/boot.efi" "$base/systemd-stub.efi" "$cmdline"
	cp "$base/systemd-boot.efi" "$dest/systemd-boot.efi"
	compose_layout "$dest/layout.sfdisk" "$base/layout.sfdisk" "$dest"
	chmod 0644 "$dest"/{boot.efi,systemd-boot.efi,layout.sfdisk} "$dest"/root-* "$dest"/roothash-* "$dest"/manifest-*
}

compose_check() { # DEST DB_CERT
	local dest=$1 cert=$2 cmdline names i n h osrel ucode pairs=()
	verify_signature "$dest/boot.efi" "$cert" || die "the composed UKI is not signed by $cert"
	verify_signature "$dest/systemd-boot.efi" "$cert" || die "systemd-boot.efi is not signed by $cert"
	cmdline=$(uki_section "$dest/boot.efi" .cmdline)
	[[ " $cmdline " == *" lockdown=integrity "* ]] || die "the composed UKI's command line lacks lockdown=integrity"
	[[ " $cmdline " != *" roothash="* && " $cmdline " != *" root="* && " $cmdline " != *" rootfstype="* ]] ||
		die "the composed UKI's command line still names a root (roothash=, root=, rootfstype=): the initrd stacks the layers"
	names=$(verify_combinations "$cmdline" | tr '\n' ' ')
	[[ $names == "${COMBO_NAMES[*]} " ]] || die "the composed UKI names '${names% }', not the combinations ${COMBO_NAMES[*]}"
	for i in "${!COMBO_NAMES[@]}"; do
		[[ $(verify_chain "$cmdline" "${COMBO_NAMES[i]}") == "${COMBO_GROUPS[i]//,/ }" ]] ||
			die "the composed UKI's chain of ${COMBO_NAMES[i]} is not ${COMBO_GROUPS[i]}"
	done
	[[ $(verify_layers "$cmdline" | tr '\n' ' ') == "${LAYER_NAMES[*]} " ]] || die "the composed UKI's layers are not ${LAYER_NAMES[*]}"
	for n in "${LAYER_NAMES[@]}"; do
		h=$(verify_layer_hash "$cmdline" "$n")
		[[ $(tr -d '[:space:]' <"$dest/roothash-$n") == "$h" ]] || die "roothash-$n is not the hash on the composed UKI's command line"
		pairs+=("$n $h")
	done
	osrel=$(uki_section "$dest/boot.efi" .osrel)
	grep -Eq '^PRETTY_NAME="safespace [0-9]{8}-[0-9]{4,6}"$' <<<"$osrel" && ! grep -q '^VARIANT_ID=' <<<"$osrel" ||
		die "the composed UKI's .osrel names a combination (it serves all): $(grep '^PRETTY_NAME=' <<<"$osrel")"
	# Microcode of both CPU vendors (security fixes the firmware may not have).
	ucode=$(objcopy -O binary --only-section=.ucode "$dest/boot.efi" /dev/stdout 2>/dev/null | cpio -t --quiet 2>/dev/null) || ucode=""
	for n in GenuineIntel AuthenticAMD; do
		grep -qx "kernel/x86/microcode/$n.bin" <<<"$ucode" || die "the composed UKI has no $n microcode (.ucode)"
	done
	objdump -h "$dest/boot.efi" | grep -q '[[:space:]]\.pcrsig[[:space:]]' || die "the composed UKI has no signed expected PCRs (.pcrsig)"
	compose_check_identity "$dest/boot.efi"
	verify_layout "$dest" "${pairs[@]}" >/dev/null || die "layout.sfdisk does not match the roots"
	log "composed UKI checked: signed by the exported db.pem, lockdown=integrity, ${#LAYER_NAMES[@]} layers by their signed hashes, ${#COMBO_NAMES[@]} combinations"
}

# The machine's secrets are sealed to the identity key (SECURITY.md, "Machine
# identity"): its public part must be in the initrd, and the .pcrsig must hold
# exactly one signature by it per bank (SHA-256 and SHA-1): for PCR 11 at
# enter-initrd, computed here from the UKI's own sections. A signature for a
# later phase would let a root unseal the secrets.
compose_check_identity() { # UKI
	local t fp s want bank args=()
	t=$(mktemp -d)
	for s in linux osrel cmdline initrd ucode splash dtb uname sbat pcrpkey profile pcrsig; do
		objcopy -O binary --only-section=".$s" "$1" "$t/$s" 2>/dev/null && [[ -s $t/$s ]] || continue
		[[ $s == pcrsig ]] || args+=("--$s=$t/$s")
	done
	[[ -s $t/initrd && -s $t/pcrsig ]] || { rm -rf "$t"; die "cannot read .initrd/.pcrsig of $1"; }
	python3 -I - "$t/initrd" >"$t/identity.pem" <<-'EOF' || { rm -rf "$t"; die "the composed UKI's initrd carries no identity key"; }
		import sys
		d = open(sys.argv[1], "rb").read()
		name = b"usr/local/lib/safespace/identity.pem\0"
		i = d.rfind(name)
		h = d[i - 110:i]
		if i < 110 or h[:6] != b"070701":
		    sys.exit(1)
		size, namesize = int(h[54:62], 16), int(h[94:102], 16)
		start = i + namesize + (-(110 + namesize) % 4)
		sys.stdout.buffer.write(d[start:start + size])
	EOF
	fp=$(openssl rsa -pubin -in "$t/identity.pem" -RSAPublicKey_out -outform DER 2>/dev/null | sha256sum | cut -c1-64)
	for bank in sha256 sha1; do
		want=$(/usr/lib/systemd/systemd-measure policy-digest "${args[@]}" --phase=enter-initrd --bank=$bank --json=short |
			python3 -I -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]][0]["pol"])' $bank) ||
			{ rm -rf "$t"; die "systemd-measure cannot compute the enter-initrd policy of $1 ($bank)"; }
		python3 -I - "$t/pcrsig" "$fp" "$want" $bank <<-'EOF' || { rm -rf "$t"; die "the composed UKI's .pcrsig: not exactly one identity signature for enter-initrd ($bank)"; }
			import json, sys
			s = json.loads(open(sys.argv[1], "rb").read().rstrip(b"\0")).get(sys.argv[4], [])
			mine = [(e["pcrs"], e["pol"]) for e in s if e["pkfp"] == sys.argv[2]]
			sys.exit(mine != [([11], sys.argv[3])])
		EOF
	done
	rm -rf "$t"
}
