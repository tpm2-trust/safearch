# Package groups: what goes into a combination on top of the base system,
# the same for sticks and network boot. Sourced by lib/compose.sh.
#
#   groups_parse LIST   "Base,Docker" -> SAFESPACE_GROUPS=(base docker)
#   groups_profiles     mkosi --profile= arguments for the parsed groups
#
# base is mkosi.conf itself and always included; every other group is the
# mkosi profile of the same name (mkosi.profiles/<group>/). mkosi.postinst
# finds the groups in $PROFILES. A new group: its profile directory and its
# name here.

GROUPS_KNOWN=(base docker xfce4-headless-vnc debug)
SAFESPACE_GROUPS=()

groups_parse() {
	local list=${1,,} g k seen=" base "
	SAFESPACE_GROUPS=(base)
	[[ $list =~ ^[a-z0-9,[:space:]-]*$ ]] || die "groups: only names separated by commas, got '$1'"
	IFS=', ' read -ra parts <<<"$list"
	for g in "${parts[@]}"; do
		[[ -n $g ]] || continue
		for k in "${GROUPS_KNOWN[@]}"; do [[ $g == "$k" ]] && break; done
		[[ $g == "$k" ]] || die "unknown package group '$g' (known: ${GROUPS_KNOWN[*]})"
		[[ $seen == *" $g "* ]] && continue
		seen+="$g "
		SAFESPACE_GROUPS+=("$g")
	done
}

groups_profiles() {
	local g
	for g in "${SAFESPACE_GROUPS[@]}"; do
		[[ $g == base ]] || echo "--profile=$g"
	done
}
