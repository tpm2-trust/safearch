# After a login: which combination this is and what its ssh host key is - from
# aSSH's status (/run/assh/status, written by the agent at boot) - and the prompt
# in its colour: pix@safespace[containers]:~$, green certified through slot 0,
# yellow through a looser slot, red with a temporary or throwaway key. Shown only,
# it decides nothing: whoever relies on the state checks it himself (an unlock the
# TPM binds). Interactive shells only (not scp, not ssh HOST COMMAND).
if [[ $- == *i* && -t 1 ]]; then
	safespace_status() {
		local c s slot why g='\e[1;32m' y='\e[1;33m' r='\e[1;31m' n='\e[0m'
		c=$(cat /usr/lib/safespace/combination 2>/dev/null)
		s=$(cat /run/assh/status 2>/dev/null)
		slot=$(sed -n 's/^slot=//p' <<<"$s")
		why=$(sed -n 's/^why=//p' <<<"$s")
		case $s in
			*certified=yes*)
				if [[ $slot == 0 ]]; then
					printf "${g}%s: the machine's identity, certified through slot 0 (approved exactly)${n}\n" "$c"
				else
					printf "${y}%s: the machine's identity, certified through slot %s: firmware or system changed since the approval${n}\n" "$c" "$slot"
					printf "${y}  after an update: sudo safespace identity approve${n}\n"
				fi ;;
			*certified=no*)
				printf "${r}%s: TEMPORARY host key, not the machine's identity: %s${n}\n" "$c" "$why"
				printf "${r}  sudo safespace identity shows why${n}\n" ;;
			*)
				printf "${r}%s: no identity: a throwaway host key (no TPM 2.0, or aSSH did not start)${n}\n" "$c" ;;
		esac
	}
	safespace_status
	unset -f safespace_status
	# The prompt: set before every prompt, as ~/.bashrc (Arch's skel) sets its
	# own PS1 after this file.
	case $(cat /run/assh/status 2>/dev/null) in
		*certified=yes*slot=0*) __safespace_color='\e[1;32m' ;;
		*certified=yes*) __safespace_color='\e[1;33m' ;;
		*) __safespace_color='\e[1;31m' ;;
	esac
	__safespace_ps1() {
		PS1="\u@\[${__safespace_color}\]\h[$(cat /usr/lib/safespace/combination 2>/dev/null)]\[\e[0m\]:\w\\$ "
	}
	PROMPT_COMMAND="__safespace_ps1${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
