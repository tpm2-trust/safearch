# Checks of a release directory, shared by release.sh (build host, before it
# pushes) and server/safespace-netboot (distribution server, which reports).
# Sourced; needs bash, sbverify, objcopy, veritysetup, sha256sum, openssl.
# No root, no temp space: everything is checked on the files as they are.
#
#   verify_release DIR VARIANT DB_CERT
#       both: boot.efi root.img root.verity roothash cmdline release SHA256SUMS
#       usb:  + systemd-boot.efi layout.sfdisk
#   release_get FILE KEY        value of KEY=... in a release file (not sourced)
#   verify_name_version VALUE
#
# What is trusted: only DB_CERT, the public Secure Boot db certificate. The
# UKI (and for usb systemd-boot) must carry a valid signature from it; the
# root hash is taken from the UKI's signed command line, and the root image
# must match it block by block. For usb the partition table must name the
# partitions by that root hash, as the initrd finds them. So a release that
# passes was built and signed by the holder of the db key, whatever path it
# took to get here. SHA256SUMS only catches broken transfers.
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

verify_release() { # DIR VARIANT DB_CERT
	local dir=$1 variant=$2 cert=$3 f version roothash cmdline url urls=0
	local files=(boot.efi root.img root.verity roothash cmdline release SHA256SUMS)
	[[ -f $cert ]] || vfail "no db certificate $cert" || return
	[[ -d $dir ]] || vfail "no release directory $dir" || return
	case $variant in
		network) ;;
		usb) files+=(systemd-boot.efi layout.sfdisk) ;;
		*) vfail "unknown variant '$variant'"; return ;;
	esac
	for f in "${files[@]}"; do
		[[ -f $dir/$f && ! -L $dir/$f ]] || vfail "$f missing" || return
	done
	verify_sums "$dir" || return
	vinfo "SHA256SUMS ok"
	[[ $(release_get "$dir/release" VARIANT) == "$variant" ]] ||
		vfail "release says VARIANT=$(release_get "$dir/release" VARIANT), expected $variant" || return
	version=$(release_get "$dir/release" VERSION)
	verify_name_version "$version" || vfail "release has an invalid VERSION='$version'" || return
	vinfo "release $(release_get "$dir/release" BUILD) (groups $(release_get "$dir/release" GROUPS))"
	roothash=$(tr -d '[:space:]' <"$dir/roothash")
	[[ $roothash =~ ^[0-9a-f]{64}$ ]] || vfail "roothash is not a sha256 root hash" || return

	verify_signature "$dir/boot.efi" "$cert" || return
	if [[ $variant == usb ]]; then
		verify_signature "$dir/systemd-boot.efi" "$cert" || return
		vinfo "boot.efi and systemd-boot.efi signed by the db key"
	else
		vinfo "boot.efi signed by the db key"
	fi
	cmdline=$(uki_cmdline "$dir/boot.efi")
	verify_cmdline_roothash "$cmdline" "$roothash" || return
	if [[ $variant == network ]]; then
		for url in $(tr ' ' '\n' <<<"$cmdline" | sed -n 's/^safespace\.netroot=//p'); do
			urls=$((urls + 1))
			vinfo "netroot URL: $url"
		done
		((urls)) || vfail "no safespace.netroot= in the UKI: not a network build" || return
	else
		verify_layout "$dir" "$roothash" || return
	fi
	vinfo "signed command line: roothash matches"
	veritysetup verify "$dir/root.img" "$dir/root.verity" "$roothash" >&2 ||
		vfail "root.img does not match the signed root hash" || return
	vinfo "root.img matches the signed root hash"
}

# The stick's partition table: an ESP, and root and verity partitions with
# the UUIDs the initrd looks for (the two halves of the root hash, as
# systemd-repart derives them), large enough for the files.
verify_layout() { # DIR ROOTHASH
	local l=$1/layout.sfdisk h=$2 t want size
	uuid_of() { sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/' <<<"$1"; }
	field() { awk -v t="$1" -v k="$2" 'toupper($0) ~ "TYPE=" t {
		n = split($0, a, ","); for (i = 1; i <= n; i++) { split(a[i], kv, "="); gsub(/ /, "", kv[1]); gsub(/[ "]/, "", kv[2]); if (kv[1] == k) print kv[2] } exit }' "$l"; }
	[[ $(grep -c 'type=' "$l") == 3 ]] || vfail "layout.sfdisk: not exactly 3 partitions" || return
	[[ -n $(field C12A7328-F81F-11D2-BA4B-00A0C93EC93B start) ]] || vfail "layout.sfdisk: no ESP" || return
	for t in "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709:${h:0:32}:root.img" "2C7357ED-EBD2-46D9-AEC1-23D437EC2BF5:${h:32}:root.verity"; do
		IFS=: read -r type half file <<<"$t"
		want=$(uuid_of "$half")
		[[ $(field "$type" uuid | tr A-F a-f) == "$want" ]] ||
			vfail "layout.sfdisk: the $file partition is not $want (from the root hash)" || return
		size=$(field "$type" size)
		[[ $size =~ ^[0-9]+$ ]] && (($(stat -c %s "$1/$file") <= size * 512)) ||
			vfail "layout.sfdisk: $file does not fit its partition" || return
	done
	vinfo "layout.sfdisk: ESP, root and verity partitions named by the root hash"
}
