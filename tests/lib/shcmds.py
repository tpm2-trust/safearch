#!/usr/bin/env python3
# shcmds.py SCRIPT...: the external commands a POSIX shell script calls (one per
# line): the first word of every simple command, without shell builtins,
# keywords, variable assignments and the script's own functions. A heuristic for
# tests/run.sh ("initrd" test), good enough for the initrd scripts' style.
import re, sys

BUILTINS = set("""
if then else elif fi for while until do done case esac in function return exit
break continue local export readonly set unset shift true false echo printf read
cd test [ [[ ]] ] . source eval exec trap wait command type hash getopts umask
let declare typeset alias unalias times ulimit kill pwd
""".split())

cmds = set()
for path in sys.argv[1:]:
    text = open(path).read()
    funcs = set(re.findall(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)', text, re.M))
    for line in text.splitlines():
        line = re.sub(r'(^|\s)#.*$', '', line)                 # comments
        line = re.sub(r"'[^']*'", "''", line)                  # single-quoted text
        line = re.sub(r'\$\(\([^()]*(\([^()]*\)[^()]*)*\)\)', '0', line)  # arithmetic
        line = re.sub(r'\$\{[^}]*\}', 'X', line)             # parameter expansion
        # double-quoted text: only the command substitutions in it count
        line = re.sub(r'"([^"\\]|\\.)*"', lambda m: ' ; '.join(re.findall(r'\$\([^()]*\)', m.group(0))) or '""', line)
        line = re.sub(r'\[\[?[^]]*\]\]?', 'true', line)    # test expressions
        for seg in re.split(r'\|\||&&|[|;&`]|\$\(|\(|\)|\{|\}|\bthen\b|\bdo\b|\belse\b', line):
            words = seg.split()
            while words and (re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', words[0]) or words[0] in ('!', 'if', 'while', 'until', 'elif')):
                words = words[1:]
            if not words:
                continue
            w = words[0].strip('"')
            if not w or w in BUILTINS or w in funcs or not re.match(r'^[/A-Za-z][A-Za-z0-9_./+-]*$', w):
                continue
            if w.endswith(')') or w.startswith('-'):
                continue
            cmds.add(w)
print('\n'.join(sorted(cmds)))
