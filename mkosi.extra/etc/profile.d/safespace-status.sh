# After a login: which combination this is and what its identity is, and the
# prompt in the identity's colour (/usr/local/lib/safespace/state.sh decides
# both, as for the safespace command), pix@safespace[containers]:~$.
# Interactive shells only (not scp, not ssh HOST COMMAND).
if [[ $- == *i* && -t 1 ]]; then
	__safespace_c=$(cat /usr/lib/safespace/combination 2>/dev/null)
	# In subshells: nothing of state.sh stays in the login shell.
	(
		. /usr/local/lib/safespace/state.sh || exit
		st=$(identity_state) c=$(state_colour "$st") n='\e[0m'
		case $st in
			green) printf "${c}%s: the machine's identity, certified through slot 0 (firmware as at the creation, a signed build)${n}\n" "$__safespace_c" ;;
			purple)
				printf "${c}%s: the machine's identity, certified through slot %s: the firmware or an option ROM changed, or the UKI is not the build's${n}\n" "$__safespace_c" "$(certified_slot)"
				printf "${c}  check it; a new identity: sudo safespace identity clear and a reboot${n}\n" ;;
			noidentity) printf "${c}%s: no identity yet: the next boot makes it${n}\n" "$__safespace_c" ;;
			unsealed) printf "${c}%s: not sealed (Secure Boot off): no identity (sudo safespace seal)${n}\n" "$__safespace_c" ;;
			temporary)
				printf "${c}%s: TEMPORARY host key, not the machine's identity: %s${n}\n" "$__safespace_c" "$(sed -n 's/^why=//p' "$STATUS" 2>/dev/null)"
				printf "${c}  safespace identity shows why${n}\n" ;;
			*) printf "${c}%s: no identity: a throwaway host key (no TPM 2.0, or aSSH did not start)${n}\n" "$__safespace_c" ;;
		esac
	)
	__safespace_color=$(. /usr/local/lib/safespace/state.sh && state_colour "$(identity_state)")
	# The prompt: set before every prompt, as ~/.bashrc (Arch's skel) sets its
	# own PS1 after this file.
	__safespace_ps1() {
		PS1="\u@\[${__safespace_color}\]\h[${__safespace_c}]\[\e[0m\]:\w\\$ "
	}
	PROMPT_COMMAND="__safespace_ps1${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
