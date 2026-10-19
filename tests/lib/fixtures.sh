# Test fixtures: throwaway Secure Boot keys, a tiny signed "UKI" and root
# images with real dm-verity hash trees, written the way mkosi writes them and
# turned into a build by the real builds_finalize. Sourced by tests/run.sh.
# No root needed.

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
# as .cmdline, which is all the release checks look at.
fx_uki() {
	local out=$1 tmp
	tmp=$(mktemp -d)
	printf '%s' "$2" >"$tmp/cmdline"
	objcopy --add-section .cmdline="$tmp/cmdline" --change-section-vma .cmdline=0x30000 \
		--set-section-flags .cmdline=data,readonly /usr/lib/systemd/boot/efi/linuxx64.efi.stub "$tmp/uki.efi" 2>/dev/null
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

# fx_info CHECKOUT VARIANT GROUPS VERSION: build.json as build.sh writes it.
fx_info() {
	local co=$1 variant=$2 groups=$3 version=$4 d id
	id="${groups//,/-}_$version"
	d=$co/mkosi.output/$variant/$id
	(
		die() { echo "$*" >&2; exit 1; }
		HERE=$co; source "$co/lib/builds.sh"
		builds_write_info "$d" build="$id" variant="$variant" version="$version" groups="$groups" debug=no \
			started="${version:0:4}-${version:4:2}-${version:6:2}T00:00:00+00:00" \
			finished="${version:0:4}-${version:4:2}-${version:6:2}T${version:9:2}:${version:11:2}:00+00:00" \
			snapshot=2099/01/01 mirror=default commit=abc1234 uncommitted_changes=no signer=test netroot= builder=test
	)
}

# fx_finish CHECKOUT VARIANT GROUPS VERSION PACKAGES...: a bare build directory
# (manifest + build.json only), for tests that only look at the bookkeeping.
fx_finish() {
	local d=$1/mkosi.output/$2/${3//,/-}_$4
	mkdir -p "$d"
	fx_manifest "$d/manifest.json" "${@:5}"
	fx_info "$1" "$2" "$3" "$4"
}

# uuid HEX32: 8-4-4-4-12, as systemd-repart derives partition UUIDs from the root hash.
fx_uuid() { sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/' <<<"$1"; }

# fx_build CHECKOUT VARIANT VERSION KEYDIR GROUPS URL PACKAGES...: what mkosi
# leaves in a build directory (for usb with the whole disk image, partition
# UUIDs from the root hash as repart sets them), then builds_finalize.
fx_build() {
	local co=$1 variant=$2 v=$3 kd=$4 groups=$5 url=$6 d b tmp hash cmdline rs vs total; shift 6
	d=$co/mkosi.output/$variant/${groups//,/-}_$v
	b=$d/safespace-arch-${variant}_$v
	mkdir -p "$d"
	tmp=$(mktemp -d)
	hash=$(fx_root "$tmp")
	cmdline="roothash=$hash systemd.volatile=state"
	[[ -n $url ]] && cmdline+=" safespace.netroot=$url"
	fx_uki "$b.efi" "$cmdline" "$kd/db/db.key" "$kd/db/db.pem"
	cp "$tmp/root.img" "$b.root.raw"
	cp "$tmp/root.verity" "$b.root-verity.raw"
	echo "$hash" >"$b.roothash"
	fx_manifest "$b.manifest" "${@:-linux=1}"
	if [[ $variant == usb ]]; then
		sbsign --key "$kd/db/db.key" --cert "$kd/db/db.pem" --output "$tmp/boot.efi" \
			/usr/lib/systemd/boot/efi/systemd-bootx64.efi >/dev/null 2>&1
		truncate -s 8M "$tmp/esp.img"
		mkfs.vfat -S 512 "$tmp/esp.img" >/dev/null
		mmd -i "$tmp/esp.img" ::/EFI ::/EFI/BOOT ::/EFI/Linux
		mcopy -i "$tmp/esp.img" "$tmp/boot.efi" ::/EFI/BOOT/BOOTX64.EFI
		mcopy -i "$tmp/esp.img" "$b.efi" "::/EFI/Linux/safespace-arch-usb_$v.efi"
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
	fi
	echo initrd >"$d/initrd.cpio.zst"
	ln -sf initrd.cpio.zst "$d/initrd"
	rm -rf "$tmp"
	(
		die() { echo "$*" >&2; exit 1; }
		HERE=$co; source "$co/lib/builds.sh"
		builds_finalize "$d" "$variant" "$v"
	) || return 1
	fx_info "$co" "$variant" "$groups" "$v"
}

# fx_resum DIR: recompute SHA256SUMS, as someone tampering with a release would.
fx_resum() {
	(cd "$1" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum >SHA256SUMS)
}
