# Test fixtures: throwaway Secure Boot keys, a tiny signed "UKI" and root
# images with real dm-verity hash trees, written the way mkosi writes them,
# turned into parts by the real builds_finalize and into a build by the real
# lib/compose.sh. Sourced by tests/run.sh. No root needed.

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

# fx_uki OUT CMDLINE KEY CERT: a signed PE (systemd-stub) carrying CMDLINE
# as .cmdline (all the release checks look at), and small dummy .linux,
# .initrd, .ucode, .osrel, .uname (what lib/compose.sh takes from a UKI).
fx_uki() {
	local out=$1 tmp s vma=0x30000 args=()
	tmp=$(mktemp -d)
	printf '%s' "$2" >"$tmp/cmdline"
	head -c 4096 /dev/urandom >"$tmp/linux"
	head -c 2048 /dev/urandom >"$tmp/initrd"
	head -c 512 /dev/urandom >"$tmp/ucode"
	printf 'ID=arch\nNAME="Arch Linux"\n' >"$tmp/osrel"
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

# uuid HEX32: 8-4-4-4-12, as systemd-repart derives partition UUIDs from the root hash.
fx_uuid() { sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/' <<<"$1"; }

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
	fx_uki "$b.efi" "$cmdline" "$kd/db/db.key" "$kd/db/db.pem"
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
			C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$rs" 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709 "$(fx_uuid "${hash:0:32}")" \
			"$vs" 2C7357ED-EBD2-46D9-AEC1-23D437EC2BF5 "$(fx_uuid "${hash:32}")" | sfdisk -q "$b.raw"
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
		compose_build "$co/mkosi.output/combined_$v" "${dirs[@]}"
		compose_check "$co/mkosi.output/combined_$v" "$kd/db/db.pem"
	) || return 1
	fx_info "$co" "$v" "${combos%,}"
}

# fx_resum DIR: recompute SHA256SUMS, as someone tampering with a release would.
fx_resum() {
	(cd "$1" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum >SHA256SUMS)
}
