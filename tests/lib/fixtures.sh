# Test fixtures: throwaway Secure Boot keys, a tiny signed "UKI" and root
# images with real dm-verity hash trees, written the way mkosi writes them,
# turned into parts by the real builds_finalize and into a build by the real
# lib/compose.sh. Sourced by tests/run.sh. No root needed.

# The partition table as the build makes it (layout_uuid, GPT_*).
# shellcheck source=lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/verify.sh"

# fx_keys DIR: a dedicated sbctl key set (PK, KEK, db, GUID) and its config.
fx_keys() {
	local dir=$1
	mkdir -p "$dir"
	cat >"$dir/sbctl.conf" <<-EOF
		keydir: $dir/keys
		guid: $dir/GUID
		files_db: $dir/files.json
		bundles_db: $dir/bundles.json
		landlock: false
	EOF
	sbctl --config "$dir/sbctl.conf" --quiet create-keys >/dev/null 2>&1
}

# fx_root DIR: root.img (random data) + root.verity, prints the root hash.
fx_root() {
	dd if=/dev/urandom of="$1/root.img" bs=1M count=4 status=none
	veritysetup format "$1/root.img" "$1/root.verity" | awk '/Root hash/ { print $3 }'
}

# fx_uki OUT CMDLINE KEY CERT [OSREL]: a signed PE (systemd-stub) carrying CMDLINE
# as .cmdline (all the release checks look at), and small dummy .linux,
# .initrd, .ucode (microcode of FX_UCODE_VENDORS, default both), .osrel (OSREL,
# default a minimal one), .uname (what lib/compose.sh takes from a UKI).
fx_uki() {
	local out=$1 tmp s vma=0x30000 args=()
	tmp=$(mktemp -d)
	printf '%s' "$2" >"$tmp/cmdline"
	head -c 4096 /dev/urandom >"$tmp/linux"
	head -c 2048 /dev/urandom >"$tmp/initrd"
	# .ucode as mkosi builds it: an early cpio with both vendors' microcode.
	mkdir -p "$tmp/uc/kernel/x86/microcode"
	for s in ${FX_UCODE_VENDORS:-GenuineIntel AuthenticAMD}; do
		head -c 256 /dev/urandom >"$tmp/uc/kernel/x86/microcode/$s.bin"
	done
	(cd "$tmp/uc" && find kernel | cpio -o -H newc --quiet) >"$tmp/ucode"
	printf '%s\n' "${5:-$(printf 'ID=arch\nNAME="Arch Linux"')}" >"$tmp/osrel"
	printf '6.0.0-fixture' >"$tmp/uname"
	for s in cmdline linux initrd ucode osrel uname; do
		args+=(--add-section ".$s=$tmp/$s" --change-section-vma ".$s=$vma" --set-section-flags ".$s=data,readonly")
		vma=$(printf '0x%x' $((vma + 0x2000)))
	done
	objcopy "${args[@]}" /usr/lib/systemd/boot/efi/linuxx64.efi.stub "$tmp/uki.efi" 2>/dev/null
	sbsign --key "$3" --cert "$4" --output "$out" "$tmp/uki.efi" >/dev/null 2>&1
	rm -rf "$tmp"
}

# fx_checkout DIR REPO: the parts of this repository the build host's tools
# need, so tests can fill its mkosi.output/ without touching the real one.
fx_checkout() {
	mkdir -p "$1/lib" "$1/mkosi.output" "$1/mkosi.extra/usr/share/safespace/secureboot"
	cp "$2/release.sh" "$2/build.sh" "$2/burn.sh" "$1/"
	cp "$2/lib/"*.sh "$1/lib/"
}

# fx_manifest FILE PACKAGES...: a mkosi manifest with name=version pairs.
fx_manifest() {
	local f=$1; shift
	python3 -I -c '
import json, sys
print(json.dumps({"packages": [{"name": p.split("=")[0], "version": p.split("=")[1]} for p in sys.argv[1:]]}))' "$@" >"$f"
}

# fx_info CHECKOUT VERSION COMBINATIONS: build.json as build.sh writes it
# (COMBINATIONS: "name:group+group,...").
fx_info() {
	local co=$1 version=$2 combos=$3 d id
	id=combined_$version
	d=$co/mkosi.output/$id
	(
		die() { echo "$*" >&2; exit 1; }
		HERE=$co; source "$co/lib/builds.sh"
		builds_write_info "$d" build="$id" version="$version" combinations="$combos" \
			started="${version:0:4}-${version:4:2}-${version:6:2}T00:00:00+00:00" \
			finished="${version:0:4}-${version:4:2}-${version:6:2}T${version:9:2}:${version:11:2}:00+00:00" \
			snapshot=2099/01/01 mirror=default commit=abc1234 uncommitted_changes=no signer=test netroot= builder=test
	)
}

# fx_finish CHECKOUT VERSION PACKAGES...: a bare build directory (one
# combination "root": manifest + build.json only), for tests that only look at
# the bookkeeping.
fx_finish() {
	local d=$1/mkosi.output/combined_$2
	mkdir -p "$d"
	fx_manifest "$d/manifest-root.json" "${@:3}"
	fx_info "$1" "$2" root:base
}


# fx_part DIR VERSION KEYDIR URL PACKAGES...: what one combination's mkosi run
# leaves in its directory (the split parts and the whole disk image, partition
# UUIDs from the root hash as repart sets them), then builds_finalize.
fx_part() {
	local d=$1 v=$2 kd=$3 url=$4 b tmp hash cmdline rs vs total; shift 4
	b=$d/safespace-arch_$v
	mkdir -p "$d"
	tmp=$(mktemp -d)
	hash=$(fx_root "$tmp")
	cmdline="roothash=$hash systemd.volatile=state lockdown=integrity"
	[[ -n $url ]] && cmdline+=" safespace.netroot=$url"
	# .osrel as mkosi.postinst and mkosi leave it (the directory is the combination's name).
	fx_uki "$b.efi" "$cmdline" "$kd/db/db.key" "$kd/db/db.pem" \
		"$(printf 'ID=arch\nNAME="Arch Linux"\nPRETTY_NAME="safespace %s %s"\nVARIANT_ID=%s\nIMAGE_ID=safespace-arch\nIMAGE_VERSION=%s' "$v" "${d##*/}" "${d##*/}" "$v")"
	cp "$tmp/root.img" "$b.root.raw"
	cp "$tmp/root.verity" "$b.root-verity.raw"
	printf %s "$hash" >"$b.roothash" # as mkosi writes it: no newline
	fx_manifest "$b.manifest" "${@:-linux=1}"
	{
		sbsign --key "$kd/db/db.key" --cert "$kd/db/db.pem" --output "$tmp/boot.efi" \
			/usr/lib/systemd/boot/efi/systemd-bootx64.efi >/dev/null 2>&1
		truncate -s 8M "$tmp/esp.img"
		mkfs.vfat -S 512 "$tmp/esp.img" >/dev/null
		mmd -i "$tmp/esp.img" ::/EFI ::/EFI/BOOT ::/EFI/Linux
		mcopy -i "$tmp/esp.img" "$tmp/boot.efi" ::/EFI/BOOT/BOOTX64.EFI
		mcopy -i "$tmp/esp.img" "$b.efi" "::/EFI/Linux/safespace-arch_$v.efi"
		rs=$(($(stat -c %s "$tmp/root.img") / 512)) vs=$((($(stat -c %s "$tmp/root.verity") + 511) / 512))
		total=$((2048 + 16384 + rs + vs + 2048))
		truncate -s $((total * 512)) "$b.raw"
		printf 'label: gpt\nstart=2048, size=16384, type=%s, name="esp"\nsize=%d, type=%s, uuid=%s, name="root-x86-64"\nsize=%d, type=%s, uuid=%s, name="root-x86-64-verity"\n' \
			"$GPT_ESP" "$rs" "$GPT_ROOT" "$(layout_uuid "${hash:0:32}")" \
			"$vs" "$GPT_VERITY" "$(layout_uuid "${hash:32}")" | sfdisk -q "$b.raw"
		dd if="$tmp/esp.img" of="$b.raw" bs=1M seek=$((2048 * 512)) oflag=seek_bytes conv=notrunc status=none
		dd if="$tmp/root.img" of="$b.raw" bs=1M seek=$((18432 * 512)) oflag=seek_bytes conv=notrunc status=none
		dd if="$tmp/root.verity" of="$b.raw" bs=1M seek=$(((18432 + rs) * 512)) oflag=seek_bytes conv=notrunc status=none
		ln -sf "$(basename "$b.raw")" "$b"
	}
	cp /usr/lib/systemd/boot/efi/linuxx64.efi.stub "$b.systemd-stub"
	echo initrd >"$d/initrd.cpio.zst"
	ln -sf initrd.cpio.zst "$d/initrd"
	rm -rf "$tmp"
	(
		die() { echo "$*" >&2; exit 1; }
		HERE=$d; source "$(dirname "${BASH_SOURCE[0]}")/../../lib/builds.sh"
		builds_finalize "$d" "$v"
	)
}

# fx_build CHECKOUT VERSION KEYDIR URL (NAME GROUPS "PACKAGES")...: a build as
# build.sh makes it: one part per combination (fx_part, kept in
# CHECKOUT/parts-VERSION/<name>/ for the tests), composed and checked by the
# real lib/compose.sh (ukify, signed expected PCRs with a throwaway key) into
# CHECKOUT/mkosi.output/combined_VERSION/, with build.json.
fx_build() {
	local co=$1 v=$2 kd=$3 url=$4 names=() groups=() dirs=() combos=""; shift 4
	[[ -f $kd/pcr.key ]] || openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=pcr/ \
		-keyout "$kd/pcr.key" -out "$kd/pcr.crt" 2>/dev/null || return 1
	[[ -f $kd/identity.key ]] || openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=identity/ \
		-keyout "$kd/identity.key" -out "$kd/identity.crt" 2>/dev/null || return 1
	while (($# >= 3)); do
		# shellcheck disable=SC2086 # the packages are words
		fx_part "$co/parts-$v/$1" "$v" "$kd" "$url" $3 || return 1
		names+=("$1") groups+=("$2") dirs+=("$co/parts-$v/$1") combos+="$1:${2//,/+},"
		shift 3
	done
	(
		set -Eeuo pipefail
		die() { echo "DIE: $*" >&2; exit 1; }
		log() { :; }
		HERE=$co
		source "$co/lib/groups.sh"; source "$co/lib/builds.sh"; source "$co/lib/verify.sh"; source "$co/lib/compose.sh"
		COMBO_NAMES=("${names[@]}") COMBO_GROUPS=("${groups[@]}")
		KEYS_SB_DIR=$kd KEYS_PCR_KEY=$kd/pcr.key KEYS_PCR_CERT=$kd/pcr.crt
		KEYS_ID_KEY=$kd/identity.key KEYS_ID_CERT=$kd/identity.crt
		compose_build "$co/mkosi.output/combined_$v" "${dirs[@]}"
		compose_check "$co/mkosi.output/combined_$v" "$kd/db/db.pem"
	) || return 1
	fx_info "$co" "$v" "${combos%,}"
	fx_release "$co/mkosi.output/combined_$v" "$kd"
}

# fx_release DIR KEYDIR: the release file and its db signature, by build.sh's code.
fx_release() {
	(HERE=${1%/mkosi.output/*}; source "$HERE/lib/builds.sh"; builds_sign_release "$1" "$2/db/db.pem" "$2/db/db.key")
}

# fx_reuki DIR KEYDIR IDENTITY_PHASES [BANKS]: rebuild DIR/boot.efi from its own
# sections, as lib/compose.sh does, but with the identity key signing the given
# phases (empty: no identity signature at all), for BANKS (sha1,sha256).
fx_reuki() {
	local d=$1 kd=$2 t s all="enter-initrd enter-initrd:leave-initrd enter-initrd:leave-initrd:sysinit enter-initrd:leave-initrd:sysinit:ready" id=()
	t=$(mktemp -d)
	for s in linux initrd ucode osrel uname cmdline; do
		objcopy -O binary --only-section=".$s" "$d/boot.efi" "$t/$s" || return 1
	done
	[[ -z $3 ]] || id=(--pcr-certificate "$kd/identity.crt" --pcr-private-key "$kd/identity.key" --phases "$3")
	ukify build --efi-arch x64 --stub /usr/lib/systemd/boot/efi/linuxx64.efi.stub --output "$t/boot.efi" \
		--linux "$t/linux" --initrd "$t/initrd" --microcode "$t/ucode" --os-release "@$t/osrel" \
		--uname "$(tr -d '\0' <"$t/uname")" --cmdline "@$t/cmdline" \
		--no-sign-kernel --signtool systemd-sbsign \
		--secureboot-private-key "$kd/db/db.key" --secureboot-certificate "$kd/db/db.pem" \
		--pcr-banks "${4:-sha1,sha256}" --pcr-certificate "$kd/pcr.crt" --pcr-private-key "$kd/pcr.key" --phases "$all" \
		"${id[@]}" >/dev/null 2>&1 || return 1
	mv "$t/boot.efi" "$d/boot.efi"
	rm -rf "$t"
}

# fx_flip FILE OFFSET: invert one byte in place - it always changes (writing a
# fixed value does not, where the byte already has it).
fx_flip() {
	local b; b=$(od -An -tu1 -j "$2" -N1 "$1" | tr -d ' ') && [[ -n $b ]] || return 1
	printf "\\x$(printf %02x $((b ^ 0xff)))" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none
}

# fx_resum DIR: recompute SHA256SUMS, as someone tampering with a release would.
fx_resum() {
	(cd "$1" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum >SHA256SUMS)
}
