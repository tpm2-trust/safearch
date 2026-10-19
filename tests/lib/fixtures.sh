# Test fixtures: throwaway Secure Boot keys, a tiny signed "UKI" and root
# images with real dm-verity hash trees, laid out like build.sh's output.
# Sourced by tests/run.sh. No root needed.

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

# fx_checkout DIR: the parts of this repository the build host's release step
# needs, so tests can fill its mkosi.output/ without touching the real one.
fx_checkout() { # DIR REPO
	mkdir -p "$1/lib" "$1/mkosi.output" "$1/mkosi.extra/usr/share/safespace/secureboot"
	cp "$2/release.sh" "$2/build.sh" "$1/"
	cp "$2/lib/"*.sh "$1/lib/"
}

# fx_finish CHECKOUT VARIANT GROUPS VERSION PACKAGES...: the build directory's
# manifest (name=version pairs) and build.json, as build.sh writes them.
# Prints the build directory.
fx_finish() {
	local co=$1 variant=$2 groups=$3 version=$4 d id; shift 4
	id="${groups//,/-}_$version"
	d=$co/mkosi.output/$variant/$id
	python3 -I -c '
import json, sys
print(json.dumps({"packages": [{"name": p.split("=")[0], "version": p.split("=")[1]} for p in sys.argv[1:]]}))' "$@" \
		>"$d/safespace-arch-${variant}_$version.manifest"
	(
		die() { echo "$*" >&2; exit 1; }
		HERE=$co; source "$co/lib/builds.sh"
		builds_write_info "$d" build="$id" variant="$variant" version="$version" groups="$groups" debug=no \
			started="${version:0:4}-${version:4:2}-${version:6:2}T00:00:00+00:00" \
			finished="${version:0:4}-${version:4:2}-${version:6:2}T${version:9:2}:${version:11:2}:00+00:00" \
			snapshot=2099/01/01 mirror=default commit=abc1234 uncommitted_changes=no signer=test netroot= builder=test
	)
	echo "$d"
}

# fx_network_build CHECKOUT VERSION URL KEYDIR GROUPS [PACKAGES...]: a network
# build in mkosi.output/network/<groups>_<version>/ as build.sh leaves it.
fx_network_build() {
	local co=$1 v=$2 url=$3 kd=$4 groups=$5 base tmp hash d; shift 5
	d=$co/mkosi.output/network/${groups//,/-}_$v
	mkdir -p "$d"
	base=$d/safespace-arch-network_$v
	tmp=$(mktemp -d)
	hash=$(fx_root "$tmp")
	fx_uki "$base.efi" "roothash=$hash safespace.netroot=$url systemd.volatile=state" "$kd/db/db.key" "$kd/db/db.pem"
	zstd -qf "$tmp/root.img" -o "$base.root.raw.zst"
	zstd -qf "$tmp/root.verity" -o "$base.root-verity.raw.zst"
	echo "$hash" >"$base.roothash"
	rm -rf "$tmp"
	fx_finish "$co" network "$groups" "$v" "${@:-linux=1}" >/dev/null
}

# fx_usb_build CHECKOUT VERSION KEYDIR GROUPS: a usb build (GPT: ESP with
# signed systemd-boot + UKI, root, root-verity) in mkosi.output/usb/<build>/.
fx_usb_build() {
	local co=$1 v=$2 kd=$3 groups=$4 base tmp hash rs vs total d
	d=$co/mkosi.output/usb/${groups//,/-}_$v
	mkdir -p "$d"
	base=$d/safespace-arch-usb_$v
	tmp=$(mktemp -d)
	hash=$(fx_root "$tmp")
	fx_uki "$tmp/uki.efi" "roothash=$hash systemd.volatile=state" "$kd/db/db.key" "$kd/db/db.pem"
	sbsign --key "$kd/db/db.key" --cert "$kd/db/db.pem" --output "$tmp/boot.efi" \
		/usr/lib/systemd/boot/efi/systemd-bootx64.efi >/dev/null 2>&1
	truncate -s 8M "$tmp/esp.img"
	mkfs.vfat -S 512 "$tmp/esp.img" >/dev/null
	mmd -i "$tmp/esp.img" ::/EFI ::/EFI/BOOT ::/EFI/Linux
	mcopy -i "$tmp/esp.img" "$tmp/boot.efi" ::/EFI/BOOT/BOOTX64.EFI
	mcopy -i "$tmp/esp.img" "$tmp/uki.efi" "::/EFI/Linux/safespace-arch-usb_$v.efi"
	rs=$(($(stat -c %s "$tmp/root.img") / 512)) vs=$((($(stat -c %s "$tmp/root.verity") + 511) / 512))
	total=$((2048 + 16384 + rs + vs + 2048))
	truncate -s $((total * 512)) "$tmp/img.raw"
	printf 'label: gpt\nstart=2048, size=16384, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B\nsize=%d, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709\nsize=%d, type=2C7357ED-EBD2-46D9-AEC1-23D437EC2BF5\n' \
		"$rs" "$vs" | sfdisk -q "$tmp/img.raw"
	dd if="$tmp/esp.img" of="$tmp/img.raw" bs=1M seek=$((2048 * 512)) oflag=seek_bytes conv=notrunc status=none
	dd if="$tmp/root.img" of="$tmp/img.raw" bs=1M seek=$((18432 * 512)) oflag=seek_bytes conv=notrunc status=none
	dd if="$tmp/root.verity" of="$tmp/img.raw" bs=1M seek=$(((18432 + rs) * 512)) oflag=seek_bytes conv=notrunc status=none
	zstd -qf "$tmp/img.raw" -o "$base.raw.zst"
	echo "$hash" >"$base.roothash"
	rm -rf "$tmp"
	fx_finish "$co" usb "$groups" "$v" linux=1 >/dev/null
}

# fx_resum DIR: recompute SHA256SUMS, as someone tampering with a release would.
fx_resum() {
	(cd "$1" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum >SHA256SUMS)
}
