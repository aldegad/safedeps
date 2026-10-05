#!/usr/bin/env python3
"""The gen set of scripts/measure/inert-record-invariant.sh: ways a command
hands text to a shell, generated from the shells' own grammar tables.

usage: python3 scripts/measure/inert-record-gen.py > scripts/measure/inert-record-gen.jsonl

Run on the host whose shells are measured; it runs each shell with harmless
scripts (`-L -c true`, `--help`, `set -o`, `shopt`, `compgen`, `command -V`)
and nothing else. The committed inert-record-gen.jsonl was written on an M1
MacBook (macOS 15.6.1: /bin/bash 3.2.57, /bin/zsh 5.9, /bin/sh, /bin/dash) on
2026-10-05; another host's shells can give another list. Every list below is read from the
shells, not written by hand, except the redirection operators and expansion
forms, which are transcribed whole from bash(1) REDIRECTION and EXPANSION and
zsh(1)/zshexpn(1) (process substitution =(...)), so the rule is "every operator
and every expansion form in those sections", not "the ones the author knew".

Rules (each form gets the prefix `npm i y && ` in pass 1):
  G1 invocation options. For S in sh, bash, zsh, dash:
     - letters: every ASCII letter L such that `S -L -c true </dev/null` exits 0
       within 3s, and every `+L` likewise (the shell's own option table, probed);
     - long options: every `--word` in `S --help` (bash, zsh; dash has none);
     - value options: `-o N`, `+o N` with N the first name `S -c 'set -o'`
       prints; bash `-O N`, `+O N` with N the first `shopt` name; every long
       option that `S --help` shows with an argument gets /dev/null.
     For each option O: `S O -c Q`, `S -c O Q`; for each letter also the clusters
     `S -Lc Q` and `S -cL Q`. Q is the payload in single quotes; the base form
     `S -c Q` is added in single and double quotes.
     Name spellings: /bin/S, the name with its first letter upper-cased, and the
     name all upper-cased (case-insensitive volumes), each as `X -c Q`.
  G2 stdin and file channels, for each S: every redirection operator of
     bash(1) REDIRECTION that can feed a shell's input (`<<<`, `<<`, `<<-`,
     `<` from a process substitution, `<&` from a here-string, `<>`), with and
     without an fd number 0, combined with each way a shell reads a script from
     input or a path (no argument, `-s`, `-`, `/dev/stdin`, `/dev/fd/0`), a pipe
     from `echo` and `printf`, a script file written then run, and a process
     substitution as the script path.
  G3 builtins and reserved words: every name of `compgen -b` and `compgen -k`
     (bash), `${(k)builtins}` and `${(k)reswords}` (zsh), and every name `dash -c
     'command -V N'` calls a builtin. Each name N gives `N Q`, `N P` (unquoted)
     and `N <(echo Q)`. Names that stop, signal or wait on processes or drive a
     terminal are left out (they hang a non-interactive harness): suspend kill
     bg fg disown jobs wait ttyctl zle zpty ztcp sched vared logout exit
     return break continue shift exec(*) -- exec is kept as `exec N`.
  G4 expansions: every expansion form of bash(1) EXPANSION that yields a word
     from text (command substitution `$( )` and backquotes, process
     substitution, parameter expansion with a word operand `:-` `-` `:=` `=`
     `:+` `+`, indirect `${!r}`, arrays `${a[@]}`, ANSI-C `$'..'`, locale
     `$".."`, `$(<file)`, zsh `=( )`), each used as (a) the whole command,
     (b) the command word, (c) the script of `sh -c`, `bash -c`, (d) the words
     of `eval`; plus quoting the command word itself ("npm", 'n'pm, n\\pm).
Pass 2 is scripts/measure/inert-record-variants.py.
"""
import json, re, subprocess, sys

P = "npm ci x"
SQ = "'npm ci x'"
DQ = '"npm ci x"'
SHELLS = ["sh", "bash", "zsh", "dash"]


def run(argv, inp=None, t=3):
    try:
        r = subprocess.run(argv, input=inp, capture_output=True, text=True, timeout=t,
                           stdin=None if inp is not None else subprocess.DEVNULL)
        return r.returncode, r.stdout + r.stderr
    except Exception:
        return 99, ""


forms = []


def add(fam, tag, cmd):
    forms.append({"fam": fam, "tag": tag, "cmd": cmd})


letters = [chr(c) for c in range(65, 91)] + [chr(c) for c in range(97, 123)]
for S in SHELLS:
    opts = []
    for L in letters:
        if L == "c":
            continue
        for sign in "-+":
            rc, _ = run(["/bin/" + S, sign + L, "-c", "true"])
            if rc == 0:
                opts.append((sign + L, True))
    rc, help_ = run(["/bin/" + S, "--help"])
    longs = []
    for m in re.finditer(r"(?<![\w-])(--[a-z][a-z0-9-]+)(=?\s?<?[A-Z_a-z]*>?)?", help_ if rc in (0, 1, 2) else ""):
        name = m.group(1)
        if name in ("--help", "--version") or name in [x for x, _ in longs]:
            continue
        arg = (m.group(2) or "").strip()
        longs.append((name, bool(arg) and arg.upper() == arg.strip("<>=").upper() and arg.strip("<>= ") != ""))
    for name, takes in longs:
        if name in ("--rcfile", "--init-file"):
            takes = True
        opts.append((name + (" /dev/null" if takes else ""), False))
    _, so = run(["/bin/" + S, "-c", "set -o"])
    names = re.findall(r"^\s*(?:set [-+]o )?([a-z][a-z0-9_]+)", so, re.M)
    if names:
        opts += [("-o " + names[0], False), ("+o " + names[0], False)]
    if S == "bash":
        _, sh = run(["/bin/bash", "-c", "shopt"])
        sn = re.findall(r"^([a-z_]+)\s", sh, re.M)
        if sn:
            opts += [("-O " + sn[0], False), ("+O " + sn[0], False)]
    for q in (SQ, DQ):
        add("G1", f"{S} -c", f"{S} -c {q}")
    for o, letter in opts:
        add("G1", f"{S} O -c ({o})", f"{S} {o} -c {SQ}")
        add("G1", f"{S} -c O ({o})", f"{S} -c {o} {SQ}")
        if letter and o[0] == "-":
            add("G1", f"{S} -Lc ({o})", f"{S} {o}c {SQ}")
            add("G1", f"{S} -cL ({o})", f"{S} -c{o[1:]} {SQ}")
    for spelled in ("/bin/" + S, S[0].upper() + S[1:], S.upper()):
        add("G1", f"name {spelled}", f"{spelled} -c {SQ}")

# G2
for S in SHELLS:
    for fd in ("", "0"):
        for how in ("", " -s", " -", " /dev/stdin", " /dev/fd/0"):
            add("G2", f"{S}{how} {fd}<<<", f"{S}{how} {fd}<<< {SQ}")
            add("G2", f"{S}{how} {fd}<<E", f"{S}{how} {fd}<<E\n{P}\nE")
            add("G2", f"{S}{how} {fd}<<-E", f"{S}{how} {fd}<<-E\n\t{P}\n\tE")
            add("G2", f"{S}{how} {fd}<<'E'", f"{S}{how} {fd}<<'E'\n{P}\nE")
            add("G2", f"{S}{how} {fd}< <()", f"{S}{how} {fd}< <(echo {SQ})")
    add("G2", f"{S} <& here-string", f"exec 3<<< {SQ}; {S} <&3")
    add("G2", f"{S} <> file", f"printf '%s\\n' {SQ} > f; {S} <> f")
    add("G2", f"{S} <(..) path", f"{S} <(echo {SQ})")
    add("G2", f"echo | {S}", f"echo {SQ} | {S}")
    add("G2", f"printf | {S}", f"printf '%s\\n' {SQ} | {S}")
    add("G2", f"file then {S}", f"printf '%s\\n' {SQ} > f; {S} f")
    add("G2", f"heredoc file then {S}", f"cat > f <<'E'\n{P}\nE\n{S} f")
    add("G2", f"{S} <<E | cat", f"{S} <<E | cat\n{P}\nE")

# G3
_, bb = run(["/bin/bash", "-c", "compgen -b; compgen -k"])
_, zb = run(["/bin/zsh", "-c", "print -l ${(k)builtins} ${(k)reswords}"])
names = sorted(set(bb.split()) | set(zb.split()))
dn = []
for n in names:
    _, o = run(["/bin/dash", "-c", f"command -V {n}"])
    if "builtin" in o:
        dn.append(n)
skip = set("suspend kill bg fg disown jobs wait ttyctl zle zpty ztcp sched vared logout exit return break continue shift".split())
for n in names:
    if n in skip:
        continue
    add("G3", f"builtin {n} sq", f"{n} {SQ}")
    add("G3", f"builtin {n} bare", f"{n} {P}")
    add("G3", f"builtin {n} <()", f"{n} <(echo {SQ})")

# G4
words = {
    "$(echo sq)": f"$(echo {SQ})", "`echo sq`": f"`echo {SQ}`",
    "${u:-P}": "${u:-npm ci x}", "${u-P}": "${u-npm ci x}", "${u:=P}": "${u:=npm ci x}",
    "${u=P}": "${u=npm ci x}", "${v:+P}": "${v:+npm ci x}", "${v+P}": "${v+npm ci x}",
    "$S": "$S", "${!r}": "${!r}", "${a[@]}": "${a[@]}", "$'P'": "$'npm ci x'",
    '$"P"': '$"npm ci x"', "$(<f)": "$(<f)", "=(echo)": f"$(cat =(echo {SQ}))",
}
pre = f"v=1 S={SQ} r=S; a=(npm ci x); printf '%s\\n' {SQ} > f; "
for k, w in words.items():
    add("G4", f"cmd {k}", pre + w)
    add("G4", f"cmd \"{k}\"", pre + f'"{w}"' if not w.startswith("$'") else pre + w)
    add("G4", f"sh -c \"{k}\"", pre + f'sh -c "{w}"')
    add("G4", f"bash -c {k}", pre + f"bash -c {w}")
    add("G4", f"eval {k}", pre + f"eval {w}")
for k, w in {"\"npm\"": '"npm" ci x', "'n'pm": "'n'pm ci x", "n\\pm": "n\\pm ci x",
             "$(echo npm)": "$(echo npm) ci x", "`echo npm`": "`echo npm` ci x",
             "${u:-npm}": "${u:-npm} ci x", "$'npm'": "$'npm' ci x", "N\"P\"M": 'N"P"M ci x'}.items():
    add("G4", f"command word {k}", w)

seen = set()
out = []
for f in forms:
    if f["cmd"] in seen:
        continue
    seen.add(f["cmd"])
    out.append(f)
for i, f in enumerate(out, 1):
    print(json.dumps({"id": f"g{i:04d}", "tag": f["fam"] + "|" + f["tag"], "cmd": "npm i y && " + f["cmd"]}, ensure_ascii=False))
print(f"generated {len(out)} forms", file=sys.stderr)
