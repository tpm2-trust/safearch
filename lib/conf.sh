# The build host's configuration (safespace.conf): sourced by build.sh,
# release.sh, update-snapshot.sh and tests/run.sh; expects die().
#
#   conf_load DIR [FILE]   DIR/safespace.conf, then DIR/safespace.local.conf, then
#                          FILE (build.sh --config); a later file's key wins
#
# The files are parsed, not sourced: KEY=VALUE lines and # comments, a value in
# "..." or '...' as it stands; only the keys of CONF_KEYS, each set as a shell
# variable of that name. What a key means and which values it takes: the
# comments in safespace.conf; each user checks the keys it uses
# (repos_validate, combos_load, settings_check).

CONF_KEYS=(COMBINATIONS USERS SNAPSHOT MIRROR NETROOT_URL RELEASE_TARGETS EROFS_WORKERS SBCTL_CONFIG
	IDENTITY_SLOTS MACHINE_ID_PCRS KEY_TYPES PCR_BANK)
# The files safespace.conf replaced: one left on the host would be dropped
# without a word (a build without its netroot URL boots from sticks only).
CONF_GONE=(repos.conf repos.local.conf netboot.conf release.conf combinations.conf)

conf_parse() { # FILE
	local file=$1 line key value n=0
	while IFS= read -r line || [[ -n $line ]]; do
		n=$((n + 1))
		line=${line%$'\r'}
		[[ $line =~ ^[[:space:]]*(#|$) ]] && continue
		[[ $line =~ ^([A-Z_0-9]+)=(.*)$ ]] || die "$file:$n: expected KEY=VALUE: $line"
		key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
		value=${value%"${value##*[![:space:]]}"}
		[[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]] && value=${BASH_REMATCH[1]}
		[[ " ${CONF_KEYS[*]} " == *" $key "* ]] || die "$file:$n: unknown key $key (the keys: safespace.conf)"
		printf -v "$key" '%s' "$value"
	done <"$file"
}

conf_load() { # DIR [FILE]
	local dir=$1 extra=${2:-} f k
	for f in "${CONF_GONE[@]}"; do
		[[ ! -e $dir/$f ]] || die "$f is no longer read: its keys go into safespace.local.conf (the keys: safespace.conf), then remove $f"
	done
	[[ -f $dir/safespace.conf ]] || die "safespace.conf missing in $dir"
	for k in "${CONF_KEYS[@]}"; do printf -v "$k" '%s' ""; done
	conf_parse "$dir/safespace.conf"
	[[ ! -f $dir/safespace.local.conf ]] || conf_parse "$dir/safespace.local.conf"
	if [[ -n $extra ]]; then
		[[ -f $extra ]] || die "--config $extra: no such file"
		conf_parse "$extra"
	fi
	return 0
}
