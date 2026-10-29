"""Upper-case variables a shell script reads that nothing sets.

usage: unset.py FILE... - the files are one script and what it sources; prints
every NAME that is read ($NAME, ${NAME}) but never assigned in any of them and
not read with a default (${NAME:-...}, ${NAME-...}, ${NAME:+...}), apart from
the shell's and the environment's own. Exit 1 if there is one.
"""
import re
import sys

SHELL = {"EUID", "UID", "HOME", "PATH", "PWD", "IFS", "TERM", "BASH_SOURCE", "BASH_REMATCH",
         "PIPESTATUS", "RANDOM", "LINENO", "FUNCNAME", "OPTARG", "OPTIND", "SUDO_UID", "SUDO_GID",
         "SUDO_USER", "SECONDS", "HOSTNAME", "USER", "LANG", "TMPDIR", "PS1", "PROMPT_COMMAND"}
text = "\n".join(open(f).read() for f in sys.argv[1:])
# comments out (a # that starts a word), not in strings: good enough for these scripts
text = re.sub(r"(^|\s)#[^\n]*", r"\1", text)
read = set(re.findall(r"\$\{?([A-Z_][A-Z0-9_]*)(?![A-Za-z0-9_])", text))
defaulted = set(re.findall(r"\$\{([A-Z_][A-Z0-9_]*)(?::?[-+=?])", text))
assigned = set(re.findall(r"(?:^|[\s;(&|])(?:local\s+|export\s+|readonly\s+)?([A-Z_][A-Z0-9_]*)\+?=", text, re.M))
assigned |= set(re.findall(r"\bfor\s+([A-Z_][A-Z0-9_]*)\s+in\b", text))
assigned |= set(re.findall(r"\bprintf\s+-v\s+\"?([A-Z_][A-Z0-9_]*)", text))
assigned |= set(re.findall(r"\b(?:mapfile|readarray)\s+(?:-[a-zA-Z]+\s+)*([A-Z_][A-Z0-9_]*)", text))
for m in re.findall(r"\bread\s+((?:-[a-zA-Z]+\s+)*)([A-Za-z_0-9 ]+)", text):
    assigned |= {w for w in m[1].split() if re.fullmatch(r"[A-Z_][A-Z0-9_]*", w)}
missing = sorted(read - assigned - defaulted - SHELL)
for n in missing:
    print(n)
sys.exit(1 if missing else 0)
