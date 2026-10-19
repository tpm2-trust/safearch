# Package groups: what goes into an image on top of the base system,
# independent of the variant (usb / network). Sourced by build.sh.
#
#   groups_parse LIST   "Base,RemoteDesktop" -> SAFESPACE_GROUPS=(base remotedesktop)
#   groups_profiles     mkosi --profile= arguments for the parsed groups
#
# base is mkosi.conf itself and always included; every other group is the
# mkosi profile of the same name (mkosi.profiles/<group>/). mkosi.postinst
# finds the groups in $PROFILES.

GROUPS_KNOWN=(base remotedesktop docker)
SAFESPACE_GROUPS=()

groups_parse() {
	local list=${1,,} g k seen=" base "
	SAFESPACE_GROUPS=(base)
	[[ $list =~ ^[a-z,[:space:]]*$ ]] || die "--groups: only names separated by commas, got '$1'"
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
