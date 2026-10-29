# The machine's identity state, decided in one place for the login
# (/etc/profile.d/safespace-status.sh) and the safespace command: sourced
# (bash). From aSSH's status of this boot (assh-agent.service) and the
# firmware's variables. Shown only, it decides nothing: whoever relies on the
# state checks it himself (an unlock the TPM binds).
#
#   green       certified through slot 0: firmware as at the creation, a build
#               the build host signed
#   purple      certified through slot 1: firmware or an option ROM changed, or
#               the UKI is not the build's - check
#   noidentity  sealed, no identity yet (the next boot makes it)
#   unsealed    Secure Boot off or Setup Mode: no identity
#   temporary   aSSH's temporary host key: the identity is another
#               combination's, or Secure Boot changed
#   throwaway   no TPM 2.0, or aSSH did not start: sshd's throwaway key
#
# SAFESPACE_SETTINGS, SAFESPACE_EFIVARS, SAFESPACE_RUNDIR: only for tests/run.sh.

# The names, GUIDs and the policy, as the initrd has them: settings (generated
# by build.sh from safespace.conf, lib/settings.sh).
. "${SAFESPACE_SETTINGS:-/usr/local/lib/safespace/settings}"
EFIVARS=${SAFESPACE_EFIVARS:-/sys/firmware/efi/efivars}
# The identity: aSSH's CA and the machine-id, in the firmware's variables.
CA_VAR=$EFIVARS/$SAFESPACE_CA_VAR
MID_VAR=$EFIVARS/$SAFESPACE_MID_VAR-$SAFESPACE_GUID
# What this boot's host key is (the agent), and what sshd serves (the agent's
# lines, or sshd-hostkeys.service's throwaway key).
STATUS=${SAFESPACE_RUNDIR:-/run}/assh/status
SSHD_HOSTKEY=${SAFESPACE_RUNDIR:-/run}/safespace/sshd-hostkey.conf

# Value byte of a global UEFI variable (after the 4-byte attribute header);
# "" where the firmware has none (no Secure Boot), also under pipefail.
var_byte() { od -An -tu1 -j4 -N1 "$EFIVARS/$1-$SAFESPACE_EFI_GLOBAL" 2>/dev/null | tr -d ' ' || true; }
sealed() { [[ $(var_byte SetupMode) == 0 && $(var_byte SecureBoot) == 1 ]]; }

# The slot that certified this boot's host key; "" for none.
certified_slot() {
	[[ $(sed -n 's/^certified=//p' "$STATUS" 2>/dev/null) == yes ]] || return 0
	sed -n 's/^slot=//p' "$STATUS"
}

identity_state() {
	local slot
	if [[ ! -s $STATUS ]]; then
		echo throwaway
		return
	fi
	slot=$(certified_slot)
	if [[ $slot == 0 ]]; then
		echo green
	elif [[ -n $slot ]]; then
		echo purple
	elif [[ -e $CA_VAR ]]; then
		echo temporary
	elif sealed; then
		echo noidentity
	else
		echo unsealed
	fi
}

state_colour() {
	case $1 in
		green) printf '\e[1;32m' ;;
		purple) printf '\e[1;35m' ;;
		noidentity) printf '\e[1;33m' ;;
		*) printf '\e[1;31m' ;;
	esac
}

# The host key sshd serves, as ssh shows it to whoever connects without the
# CA's line: "<type> <base64>".
served_hostkey() {
	local k
	k=$(sed -n 's/^HostKey //p' "$SSHD_HOSTKEY" 2>/dev/null | head -1)
	[[ -n $k ]] || return 0
	[[ $k == *.pub ]] || k=$k.pub
	cut -d' ' -f1,2 "$k" 2>/dev/null
}
