# Checks of a release directory, shared by release.sh (build host, before it
# pushes) and server/safespace-netboot (distribution server, which reports).
# Sourced; needs bash, sbverify, objcopy, veritysetup, sha256sum, openssl.
# No root, no temp space: everything is checked on the files as they are.
#
#   verify_release DIR DB_CERT
#       boot.efi systemd-boot.efi layout.sfdisk cmdline release SHA256SUMS,
#       per combination root-<name>.img root-<name>.verity roothash-<name>
#   verify_combinations CMDLINE  the combination names on a signed command line
#   release_get FILE KEY        value of KEY=... in a release file (not sourced)
#   verify_name_version VALUE
#
# What is trusted: only DB_CERT, the public Secure Boot db certificate. The
# UKI and systemd-boot must carry a valid signature from it; the root hashes
# are taken from the UKI's signed command line (safespace.root.<name>=), and
# each root image must match its hash block by block. The partition table for
# sticks must name the partitions by those root hashes, as the initrd finds
# them. So a release that
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

verify_combinations() { # CMDLINE
	tr ' ' '\n' <<<"$1" | sed -n 's/^safespace\.root\.\([a-z][a-z0-9-]*\)=[0-9a-f]\{64\}$/\1/p'
}

# The release file's signature (release.p7s, detached CMS) by the db key:
# that certificate alone, given here (-nointern), whatever the signature
# carries; the same check a machine makes before it updates (safespace update).
verify_release_file() { # RELEASE P7S DB_CERT
	openssl cms -verify -binary -inform DER -in "$2" -content "$1" -certfile "$3" -nointern -noverify -out /dev/null 2>/dev/null
}

verify_release() { # DIR DB_CERT
	local dir=$1 cert=$2 f version cmdline url urls=0 n h names=() pairs=()
	[[ -f $cert ]] || vfail "no db certificate $cert" || return
	[[ -d $dir ]] || vfail "no release directory $dir" || return
	for f in boot.efi systemd-boot.efi layout.sfdisk cmdline release release.p7s SHA256SUMS; do
		[[ -f $dir/$f && ! -L $dir/$f ]] || vfail "$f missing" || return
	done
	verify_sums "$dir" || return
	vinfo "SHA256SUMS ok"
	verify_release_file "$dir/release" "$dir/release.p7s" "$cert" ||
		vfail "release is not signed by the db key (release.p7s)" || return
	vinfo "release signed by the db key"
	version=$(release_get "$dir/release" VERSION)
	verify_name_version "$version" || vfail "release has an invalid VERSION='$version'" || return
	vinfo "release $(release_get "$dir/release" BUILD)"

	verify_signature "$dir/boot.efi" "$cert" || return
	verify_signature "$dir/systemd-boot.efi" "$cert" || return
	vinfo "boot.efi and systemd-boot.efi signed by the db key"
	cmdline=$(uki_cmdline "$dir/boot.efi")
	[[ " $cmdline " == *" lockdown=integrity "* ]] || vfail "the UKI's signed command line lacks lockdown=integrity" || return
	for url in $(tr ' ' '\n' <<<"$cmdline" | sed -n 's/^safespace\.netroot=//p'); do
		urls=$((urls + 1))
		vinfo "netroot URL: $url"
	done
	((urls)) || vinfo "no safespace.netroot= in the UKI: this release boots from sticks only"

	# One root per combination, its hash from the signed command line.
	mapfile -t names < <(verify_combinations "$cmdline")
	((${#names[@]})) || vfail "the UKI's signed command line names no combination (safespace.root.<name>=)" || return
	[[ $(release_get "$dir/release" COMBINATIONS) == "$(IFS=,; echo "${names[*]}")" ]] ||
		vfail "release names COMBINATIONS=$(release_get "$dir/release" COMBINATIONS), the signed command line ${names[*]}" || return
	vinfo "combinations on the signed command line: ${names[*]} (default ${names[0]})"
	for n in "${names[@]}"; do
		h=$(tr ' ' '\n' <<<"$cmdline" | sed -n "s/^safespace\.root\.$n=//p")
		for f in "root-$n.img" "root-$n.verity" "roothash-$n"; do
			[[ -f $dir/$f && ! -L $dir/$f ]] || vfail "$f missing" || return
		done
		[[ $(tr -d '[:space:]' <"$dir/roothash-$n") == "$h" ]] ||
			vfail "roothash-$n is not the root hash on the UKI's signed command line" || return
		veritysetup verify "$dir/root-$n.img" "$dir/root-$n.verity" "$h" >&2 ||
			vfail "root-$n.img does not match the signed root hash" || return
		vinfo "root-$n.img matches the signed root hash"
		pairs+=("$n $h")
	done
	verify_layout "$dir" "${pairs[@]}" || return
}

# The stick's partition table: an ESP, and for each combination a root and a
# verity partition (root-<name>, root-<name>-verity) with the UUIDs the initrd
# looks for (the two halves of the root hash, as systemd-repart derives them),
# large enough for the files.
verify_layout() { # DIR "NAME HASH"...
	local dir=$1 l=$1/layout.sfdisk p n h want size uuid type name half file; shift
	uuid_of() { sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/' <<<"$1"; }
	part() { # TYPE PARTNAME KEY: a value of the partition with that type and name
		awk -v t="$1" -v pn="$2" -v k="$3" 'toupper($0) ~ "TYPE=" t && $0 ~ "name=\"" pn "\"" {
			n = split($0, a, ","); for (i = 1; i <= n; i++) { split(a[i], kv, "="); gsub(/ /, "", kv[1]); gsub(/[ "]/, "", kv[2]); if (kv[1] == k) print kv[2] } exit }' "$l"; }
	[[ $(grep -c 'type=' "$l") == $((1 + 2 * $#)) ]] || vfail "layout.sfdisk: not 1 + 2 x $# partitions" || return
	grep -qi 'type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B' "$l" || vfail "layout.sfdisk: no ESP" || return
	for p in "$@"; do
		read -r n h <<<"$p"
		for x in "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709:root-$n:${h:0:32}:root-$n.img" "2C7357ED-EBD2-46D9-AEC1-23D437EC2BF5:root-$n-verity:${h:32}:root-$n.verity"; do
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
