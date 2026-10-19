# Checks of a release directory, shared by release.sh (build host, before it
# pushes) and server/safespace-netboot (distribution server, which reports).
# Sourced; needs bash, sbverify, objcopy, veritysetup, sha256sum, openssl.
# No root, no temp space: everything is checked on the files as they are.
#
#   verify_release DIR DB_CERT
#       boot.efi root.img root.verity roothash systemd-boot.efi layout.sfdisk
#       cmdline release SHA256SUMS
#   release_get FILE KEY        value of KEY=... in a release file (not sourced)
#   verify_name_version VALUE
#
# What is trusted: only DB_CERT, the public Secure Boot db certificate. The
# UKI and systemd-boot must carry a valid signature from it; the root hash is
# taken from the UKI's signed command line, and the root image must match it
# block by block. The partition table for sticks must name the partitions by
# that root hash, as the initrd finds them. So a release that
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

verify_release() { # DIR DB_CERT
	local dir=$1 cert=$2 f version cmdline url urls=0 n h names=() pairs=()
	[[ -f $cert ]] || vfail "no db certificate $cert" || return
	[[ -d $dir ]] || vfail "no release directory $dir" || return
	for f in boot.efi systemd-boot.efi layout.sfdisk cmdline release SHA256SUMS; do
		[[ -f $dir/$f && ! -L $dir/$f ]] || vfail "$f missing" || return
	done
	verify_sums "$dir" || return
	vinfo "SHA256SUMS ok"
	version=$(release_get "$dir/release" VERSION)
	verify_name_version "$version" || vfail "release has an invalid VERSION='$version'" || return
	vinfo "release $(release_get "$dir/release" BUILD) (groups $(release_get "$dir/release" GROUPS))"

	verify_signature "$dir/boot.efi" "$cert" || return
	verify_signature "$dir/systemd-boot.efi" "$cert" || return
	vinfo "boot.efi and systemd-boot.efi signed by the db key"
	cmdline=$(uki_cmdline "$dir/boot.efi")
	for url in $(tr ' ' '\n' <<<"$cmdline" | sed -n 's/^safespace\.netroot=//p'); do
		urls=$((urls + 1))
		vinfo "netroot URL: $url"
	done
	((urls)) || vinfo "no safespace.netroot= in the UKI: this release boots from sticks only"

	# The roots: one (roothash=), or one per combination (safespace.root.<name>=);
	# each "name file-suffix root-hash partition-name" ("_" = no suffix).
	mapfile -t names < <(tr ' ' '\n' <<<"$cmdline" | sed -n 's/^safespace\.root\.\([a-z][a-z0-9-]*\)=[0-9a-f]\{64\}$/\1/p')
	if ((${#names[@]})); then
		[[ $(release_get "$dir/release" COMBINATIONS) == "$(IFS=,; echo "${names[*]}")" ]] ||
			vfail "release names COMBINATIONS=$(release_get "$dir/release" COMBINATIONS), the signed command line ${names[*]}" || return
		for n in "${names[@]}"; do
			h=$(tr ' ' '\n' <<<"$cmdline" | sed -n "s/^safespace\.root\.$n=//p")
			pairs+=("$n -$n $h root-$n")
		done
		vinfo "combinations on the signed command line: ${names[*]}"
	else
		h=$(tr ' ' '\n' <<<"$cmdline" | sed -n 's/^roothash=//p' | tail -1)
		pairs+=("- _ $h root-x86-64")
	fi
	for p in "${pairs[@]}"; do
		read -r n f h _ <<<"$p"
		[[ $f == _ ]] && f=""
		for x in "root$f.img" "root$f.verity" "roothash$f"; do
			[[ -f $dir/$x && ! -L $dir/$x ]] || vfail "$x missing" || return
		done
		[[ $h =~ ^[0-9a-f]{64}$ && $(tr -d '[:space:]' <"$dir/roothash$f") == "$h" ]] ||
			vfail "roothash$f is not the root hash on the UKI's signed command line" || return
		veritysetup verify "$dir/root$f.img" "$dir/root$f.verity" "$h" >&2 ||
			vfail "root$f.img does not match the signed root hash" || return
		vinfo "root$f.img matches the signed root hash"
	done
	verify_layout "$dir" "${pairs[@]}" || return
}

# The stick's partition table: an ESP, and for each root a root and a verity
# partition with the UUIDs the initrd looks for (the two halves of the root
# hash, as systemd-repart derives them), large enough for the files.
verify_layout() { # DIR "NAME SUFFIX HASH PARTNAME"...
	local dir=$1 l=$1/layout.sfdisk p n f h pn want field size uuid; shift
	uuid_of() { sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/' <<<"$1"; }
	part() { # TYPE PARTNAME KEY: a value of the partition with that type and name
		awk -v t="$1" -v pn="$2" -v k="$3" 'toupper($0) ~ "TYPE=" t && $0 ~ "name=\"" pn "\"" {
			n = split($0, a, ","); for (i = 1; i <= n; i++) { split(a[i], kv, "="); gsub(/ /, "", kv[1]); gsub(/[ "]/, "", kv[2]); if (kv[1] == k) print kv[2] } exit }' "$l"; }
	[[ $(grep -c 'type=' "$l") == $((1 + 2 * $#)) ]] || vfail "layout.sfdisk: not 1 + 2 x $# partitions" || return
	grep -qi 'type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B' "$l" || vfail "layout.sfdisk: no ESP" || return
	for p in "$@"; do
		read -r n f h pn <<<"$p"
		[[ $f == _ ]] && f=""
		for x in "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709:$pn:${h:0:32}:root$f.img" "2C7357ED-EBD2-46D9-AEC1-23D437EC2BF5:$pn-verity:${h:32}:root$f.verity"; do
			IFS=: read -r type name half file <<<"$x"
			want=$(uuid_of "$half")
			uuid=$(part "$type" "$name" uuid | tr A-F a-f)
			[[ $uuid == "$want" ]] || vfail "layout.sfdisk: partition $name is not $want (from the root hash)" || return
			size=$(part "$type" "$name" size)
			[[ $size =~ ^[0-9]+$ ]] && (($(stat -c %s "$dir/$file") <= size * 512)) ||
				vfail "layout.sfdisk: $file does not fit partition $name" || return
		done
	done
	vinfo "layout.sfdisk: ESP and $# root/verity pair(s) named by their root hashes"
}
