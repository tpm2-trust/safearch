# Checks of a release directory, shared by release.sh (build host, before it
# pushes) and server/safespace-netboot (distribution server, before it serves).
# Sourced; needs bash, sbverify, objcopy, veritysetup, sha256sum, zstd, sfdisk,
# mtools, dd. No root, no python.
#
#   verify_release DIR VARIANT DB_CERT [TMPDIR]
#       network: boot.efi root.img root.verity roothash cmdline release SHA256SUMS
#       usb:     image.raw.zst roothash release SHA256SUMS (TMPDIR: room for the
#                unpacked image plus a copy of its root partition)
#   release_get FILE KEY        value of KEY=... in a release file (not sourced)
#   verify_name_version VALUE
#
# What is trusted: only DB_CERT, the public Secure Boot db certificate. The
# UKI must carry a valid signature from it; the root hash is taken from the
# UKI's signed command line, and the root image must match it block by block.
# So a release that passes was built and signed by the holder of the db key,
# whatever path it took to get here. SHA256SUMS only catches broken transfers.
# On failure: a message on stderr and return 1.

vfail() { printf '%s\n' "$*" >&2; return 1; }
vinfo() { printf '    %s\n' "$*"; }

# Versions are what build.sh writes (date-time, optional suffix).
verify_name_version() { [[ $1 =~ ^[0-9][0-9A-Za-z._-]{0,63}$ ]]; }

release_get() { # FILE KEY
	sed -n "s/^$2=//p" "$1" | head -1
}

uki_cmdline() { # FILE
	objcopy -O binary --only-section=.cmdline "$1" /dev/stdout 2>/dev/null | tr -d '\0'
}

verify_signature() { # FILE DB_CERT
	sbverify --cert "$2" "$1" >/dev/null 2>&1 ||
		vfail "$(basename "$1"): no valid Secure Boot signature by $(openssl x509 -in "$2" -noout -subject 2>/dev/null || echo "$2")"
}

# Every file in DIR (except SHA256SUMS and dotfiles) is listed and matches.
verify_sums() { # DIR
	local dir=$1 f listed
	[[ -f $dir/SHA256SUMS ]] || vfail "no SHA256SUMS" || return
	listed=$(awk '{ sub(/^\*/, "", $2); print $2 }' "$dir/SHA256SUMS" | sort)
	for f in $(cd "$dir" && find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name '.*' -printf '%P\n' | sort); do
		grep -qxF "$f" <<<"$listed" || vfail "$f is not in SHA256SUMS" || return
	done
	(cd "$dir" && sha256sum --quiet --strict -c SHA256SUMS) >&2 || vfail "SHA256SUMS does not match (broken or incomplete transfer)"
}

# The signed command line: roothash= must be the release's root hash.
verify_cmdline_roothash() { # CMDLINE ROOTHASH
	[[ -n $2 && " $1 " == *" roothash=$2 "* ]] ||
		vfail "the UKI's signed command line does not carry roothash=$2"
}

verify_release() { # DIR VARIANT DB_CERT [TMPDIR]
	local dir=$1 variant=$2 cert=$3 tmp=${4:-} f version
	[[ -f $cert ]] || vfail "no db certificate $cert" || return
	[[ -d $dir ]] || vfail "no release directory $dir" || return
	case $variant in
		network) for f in boot.efi root.img root.verity roothash cmdline release SHA256SUMS; do
			[[ -f $dir/$f && ! -L $dir/$f ]] || vfail "$f missing" || return
		done ;;
		usb) for f in image.raw.zst roothash release SHA256SUMS; do
			[[ -f $dir/$f && ! -L $dir/$f ]] || vfail "$f missing" || return
		done ;;
		*) vfail "unknown variant '$variant'"; return ;;
	esac
	verify_sums "$dir" || return
	vinfo "SHA256SUMS ok"
	[[ $(release_get "$dir/release" VARIANT) == "$variant" ]] ||
		vfail "release says VARIANT=$(release_get "$dir/release" VARIANT), expected $variant" || return
	version=$(release_get "$dir/release" VERSION)
	verify_name_version "$version" || vfail "release has an invalid VERSION='$version'" || return
	vinfo "release $version (groups $(release_get "$dir/release" GROUPS))"
	local roothash
	roothash=$(tr -d '[:space:]' <"$dir/roothash")
	[[ $roothash =~ ^[0-9a-f]{64}$ ]] || vfail "roothash is not a sha256 root hash" || return
	"verify_$variant" "$dir" "$cert" "$roothash" "$tmp"
}

verify_network() { # DIR DB_CERT ROOTHASH
	local dir=$1 cert=$2 roothash=$3 cmdline url urls=0
	verify_signature "$dir/boot.efi" "$cert" || return
	vinfo "boot.efi signed by the db key"
	cmdline=$(uki_cmdline "$dir/boot.efi")
	verify_cmdline_roothash "$cmdline" "$roothash" || return
	for url in $(tr ' ' '\n' <<<"$cmdline" | sed -n 's/^safespace\.netroot=//p'); do
		urls=$((urls + 1))
		vinfo "netroot URL: $url"
	done
	((urls)) || vfail "no safespace.netroot= in the UKI: not a network build" || return
	vinfo "signed command line: roothash matches"
	veritysetup verify "$dir/root.img" "$dir/root.verity" "$roothash" >&2 ||
		vfail "root.img does not match the signed root hash" || return
	vinfo "root.img matches the signed root hash"
}

verify_usb() { # DIR DB_CERT ROOTHASH TMPDIR
	local dir=$1 cert=$2 roothash=$3 tmp=$4 raw esp root verity uki cmdline
	[[ -n $tmp && -d $tmp ]] || vfail "verify_usb needs a temporary directory" || return
	raw=$tmp/image.raw
	zstd -dqf "$dir/image.raw.zst" -o "$raw" || vfail "image.raw.zst does not decompress" || return
	# start and size (512-byte sectors) of a partition by GPT type
	part() { sfdisk -d "$raw" 2>/dev/null | awk -F'[=,]' -v t="$1" 'toupper($0) ~ "TYPE=" t { gsub(/ /, ""); print $2, $4; exit }'; }
	esp=$(part C12A7328-F81F-11D2-BA4B-00A0C93EC93B)
	root=$(part 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709)
	verity=$(part 2C7357ED-EBD2-46D9-AEC1-23D437EC2BF5)
	[[ -n $esp && -n $root && -n $verity ]] || vfail "image has not the ESP + root + root-verity layout" || return
	local off=$((${esp% *} * 512))
	mcopy -n -i "$raw@@$off" ::/EFI/BOOT/BOOTX64.EFI "$tmp/BOOTX64.EFI" 2>/dev/null ||
		vfail "no \\EFI\\BOOT\\BOOTX64.EFI on the ESP" || return
	mapfile -t uki < <(mdir -b -i "$raw@@$off" ::/EFI/Linux/ 2>/dev/null | grep -i '\.efi$')
	((${#uki[@]} == 1)) || vfail "expected exactly one UKI in \\EFI\\Linux, found ${#uki[@]}" || return
	mcopy -n -i "$raw@@$off" "${uki[0]}" "$tmp/uki.efi" || return
	verify_signature "$tmp/BOOTX64.EFI" "$cert" || return
	verify_signature "$tmp/uki.efi" "$cert" || return
	vinfo "systemd-boot and the UKI signed by the db key"
	cmdline=$(uki_cmdline "$tmp/uki.efi")
	verify_cmdline_roothash "$cmdline" "$roothash" || return
	vinfo "signed command line: roothash matches"
	# veritysetup needs the data at offset 0 of a file: cut the partitions out.
	for p in root verity; do
		set -- ${!p}
		dd if="$raw" of="$tmp/$p.img" bs=4M iflag=skip_bytes,count_bytes skip=$(($1 * 512)) count=$(($2 * 512)) status=none || return
	done
	rm -f "$raw"
	veritysetup verify "$tmp/root.img" "$tmp/verity.img" "$roothash" >&2 ||
		vfail "the root partition does not match the signed root hash" || return
	vinfo "root partition matches the signed root hash"
	rm -f "$tmp/root.img" "$tmp/verity.img" "$tmp/BOOTX64.EFI" "$tmp/uki.efi"
}
