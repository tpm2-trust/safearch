# After a login: which combination this is and what its identity is - from
# aSSH's status (/run/assh/status, written by the agent at boot) and the
# firmware's Secure Boot state - and the prompt in its colour,
# pix@safespace[containers]:~$:
#   green   certified through slot 0: firmware as at the creation, a build the
#           build host signed
#   purple  certified through slot 1: firmware or an option ROM changed, or the
#           UKI is not the build's - check
#   yellow  sealed, no identity yet (the next boot makes it)
#   red     not sealed; a temporary key (not this machine's identity); a
#           throwaway key (no TPM, aSSH did not start)
# Shown only, it decides nothing: whoever relies on the state checks it himself
# (an unlock the TPM binds). Interactive shells only (not scp, not ssh HOST COMMAND).
if [[ $- == *i* && -t 1 ]]; then
	__safespace_state() {
		local s v=/sys/firmware/efi/efivars g=8be4df61-93ca-11d2-aa0d-00e098032b8c
		s=$(cat /run/assh/status 2>/dev/null)
		case $s in
			*certified=yes*slot=0*) echo green ;;
			*certified=yes*) echo purple ;;
			*certified=no*)
				if [[ -e $v/SAFEasshCA-24415b90-39be-45c0-a9a3-d547ebe28ea0 ]]; then
					echo temporary
				elif [[ $(od -An -tu1 -j4 -N1 $v/SetupMode-$g 2>/dev/null | tr -d ' ') == 0 &&
					$(od -An -tu1 -j4 -N1 $v/SecureBoot-$g 2>/dev/null | tr -d ' ') == 1 ]]; then
					echo noidentity
				else
					echo unsealed
				fi ;;
			*) echo throwaway ;;
		esac
	}
	__safespace_status() {
		local c=$1 st=$2 slot why
		local g='\e[1;32m' p='\e[1;35m' y='\e[1;33m' r='\e[1;31m' n='\e[0m'
		slot=$(sed -n 's/^slot=//p' /run/assh/status 2>/dev/null)
		why=$(sed -n 's/^why=//p' /run/assh/status 2>/dev/null)
		case $st in
			green) printf "${g}%s: the machine's identity, certified through slot 0 (approved firmware, a signed build)${n}\n" "$c" ;;
			purple)
				printf "${p}%s: the machine's identity, certified through slot %s: the firmware or an option ROM changed, or the UKI is not the build's${n}\n" "$c" "$slot"
				printf "${p}  check it; a new identity: sudo safespace identity clear and a reboot${n}\n" ;;
			noidentity) printf "${y}%s: no identity yet: the next boot makes it${n}\n" "$c" ;;
			unsealed) printf "${r}%s: not sealed (Secure Boot off): no identity (sudo safespace seal)${n}\n" "$c" ;;
			temporary)
				printf "${r}%s: TEMPORARY host key, not the machine's identity: %s${n}\n" "$c" "$why"
				printf "${r}  safespace identity shows why${n}\n" ;;
			*) printf "${r}%s: no identity: a throwaway host key (no TPM 2.0, or aSSH did not start)${n}\n" "$c" ;;
		esac
	}
	__safespace_c=$(cat /usr/lib/safespace/combination 2>/dev/null)
	__safespace_st=$(__safespace_state)
	__safespace_status "$__safespace_c" "$__safespace_st"
	unset -f __safespace_status __safespace_state
	# The prompt: set before every prompt, as ~/.bashrc (Arch's skel) sets its
	# own PS1 after this file.
	case $__safespace_st in
		green) __safespace_color='\e[1;32m' ;;
		purple) __safespace_color='\e[1;35m' ;;
		noidentity) __safespace_color='\e[1;33m' ;;
		*) __safespace_color='\e[1;31m' ;;
	esac
	__safespace_ps1() {
		PS1="\u@\[${__safespace_color}\]\h[${__safespace_c}]\[\e[0m\]:\w\\$ "
	}
	PROMPT_COMMAND="__safespace_ps1${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
