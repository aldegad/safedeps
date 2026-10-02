#!/usr/bin/env bash
# safedeps: every manager's option reading but npm's, asked of the manager.
#
# lib/install-grammar.sh reads a manager's words with a table of the options
# that take a value (SAFEDEPS_G_VALUE_OPTIONS). An option the table leaves out
# is read as a switch, so its value becomes an extra operand: a spurious check
# at worst. The other direction hides a package. An entry for an option the
# manager reads as a switch takes the next word for its value, and when that
# word is the package, nothing checks it. bun's runtime options were listed for
# every bun command, so `bun add --print evil@1.0.0` installed evil with no
# check and no record: bun reads `--print` as a switch there.
#
# A help text cannot settle this for every manager. bun prints `-c,
# --config=<val>` and reads `bun add -c x` as installing x, because its value
# is optional, and it reads an option it does not know as a switch. So this
# asks each manager on PATH how it reads a form, the way it can be asked:
#
#   bun     runs it: `bun add <opt> ../sdv ../sdw` against synthetic local
#           packages, the registry a closed port, and reads what it installed;
#           `bun <opt> add ../sdv` before the command; `bun x <opt> sdv a1` and
#           `bunx <opt> sdv a1` against a local binary, and reads what it ran
#           or tried to fetch. `bun update <opt> ../sdv` is read from the
#           words its error quotes. Every option any of these commands'
#           --help prints, every option `bun --help` prints and every option
#           in the table.
#   pip     its own parser (optparse, in pip's modules), in place and before
#           the command, for every option it defines, every option in the
#           table, and every prefix of a table option it would expand.
#   python  runs `python3 <options> --version` and reads whether pip answered,
#           for clusters of one-letter options (`-Im pip`, `-Impip`).
#   uv, cargo, go
#           their help: clap prints a value it requires as `<VALUE>` and one it
#           does not as `[<VALUE>]`, and refuses an option it does not define;
#           go's help prints a flag's argument after it.
#
# Each form names a target word, a package. The manager reads it as a package
# it installs or runs (N), as an option's value (V), or refuses the form (X).
# The grammar reads it with safedeps_manager_read, as a package or not. The
# manager installing a word the grammar does not read as a package is a
# failure (OVER): the table lists a value the manager does not take. The
# reverse is printed (UNDER: a value the table does not list, a spurious
# check) and does not fail.
#
# A manager not on PATH is skipped by name: pnpm, yarn, pipx, poetry, pipenv,
# gem, bundle, dotnet and mvn are not asked anywhere this has run, and their
# tables stay what their help and source say. Nothing here reaches a registry.
#
# bun is run, so it runs the way the batteries that run npm do: every package
# is synthetic and local, every registry setting points at a closed local
# port, and its home, cache and global directory are this run's own, with no
# npm_config_* or BUN_* setting inherited (npm test exports npm's own).
#
# Usage: scripts/measure/manager-option-reading.sh [--tree <dir>] [<family>...]
#   --tree <dir>  judge with the grammar of another checkout (the controls)
#   <family>      ask only these (bun pip python uv cargo go)
# Exit: 0 every manager asked agrees, 1 a disagreement (printed), 3 no manager
#       on PATH to ask (each named).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TREE="${ROOT_DIR}"
if [[ "${1:-}" == --tree ]]; then
  TREE=$(cd "$2" && pwd)
  shift 2
fi
# shellcheck source=../../lib/install-grammar.sh
source "${TREE}/lib/install-grammar.sh"

families=(bun pip python uv cargo go)
[[ $# -eq 0 ]] || families=("$@")

work=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-manager-options.XXXXXX")
trap 'rm -rf "${work}"' EXIT
over=0 under=0 forms=0
asked=() skipped=()

# The grammar's reading of word <index> of a statement: a package role or not.
grammar_role() {
  local k="$1"
  shift
  safedeps_manager_read "$@" || { printf '!'; return 0; }
  printf '%s' "${SAFEDEPS_G_M_ROLE[k]:--}"
}

# judge <family> <manager answer> <target index> <words...>
judge() {
  local family="$1" answer="$2" k="$3" role pkg=false
  shift 3
  role=$(grammar_role "${k}" "$@")
  case "${role}" in o|r|C|p|w|D) pkg=true ;; esac
  # A value the grammar reads as the package an option names (`bunx -p x`,
  # `uvx --from x`) is both.
  [[ "${answer}" != V || ( "${role}" != p && "${role}" != w ) ]] || pkg=false
  forms=$((forms + 1))
  if [[ "${answer}" == N && "${pkg}" == false ]]; then
    over=$((over + 1))
    printf 'OVER %s: the manager reads [%s] as a package; the grammar reads it as [%s] in: %s\n' \
      "${family}" "${*:k+1:1}" "${role}" "$*"
  elif [[ "${answer}" == V && "${pkg}" == true ]]; then
    under=$((under + 1))
    printf 'UNDER %s: the manager reads [%s] as a value; the grammar checks it as a package in: %s\n' \
      "${family}" "${*:k+1:1}" "$*"
  fi
}

# The options a help text prints: `-x` and `--name`, one per line.
help_options() {
  LC_ALL=C grep -oE '^[[:space:]]+(-[A-Za-z0-9], )?--?[A-Za-z0-9][A-Za-z0-9._-]*' \
    | LC_ALL=C sed -E 's/^[[:space:]]+//' | tr -s ', ' '\n\n' || true
}

# Every option of <family> in the table, one per line.
table_options() {
  local e
  (set -f
   for e in ${SAFEDEPS_G_VALUE_OPTIONS}; do
     [[ "${e}" == "$1"/* ]] || continue
     e="${e#*:}"
     printf '%s\n' "${e%=*}"
   done)
}

ask_bun() {
  command -v bun >/dev/null 2>&1 || return 3
  local version c o b out dir n=0 answer
  version=$(bun --version)
  while IFS= read -r v; do unset "${v}"; done < <(env | LC_ALL=C sed -nE 's/^((npm_config_|NPM_CONFIG_|BUN_)[A-Za-z0-9_]*)=.*/\1/p')
  export HOME="${work}/home" BUN_INSTALL="${work}/bun-install" BUN_INSTALL_CACHE_DIR="${work}/bun-cache" \
    BUN_CONFIG_REGISTRY=http://127.0.0.1:9 NPM_CONFIG_REGISTRY=http://127.0.0.1:9 \
    npm_config_registry=http://127.0.0.1:9
  mkdir -p "${HOME}" "${BUN_INSTALL}"
  {
    bun --help 2>&1 | help_options
    for c in add install update x; do bun "${c}" --help 2>&1 | help_options; done
    table_options bun
    table_options bunx
  } | LC_ALL=C sort -u | grep -vE '^-(h|-help|v|-version|-revision)$' > "${work}/bun.options"

  # One form per directory: synthetic packages beside a project with a
  # local binary, so nothing is fetched.
  bun_form() {
    local b="$1" mode="$2"
    shift 2
    mkdir -p "${b}/proj/node_modules/.bin" "${b}/proj/node_modules/sdv"
    for p in sdv sdw; do
      mkdir -p "${b}/${p}"
      printf '{"name":"%s","version":"1.0.0"}\n' "${p}" > "${b}/${p}/package.json"
    done
    printf '{"name":"proj","version":"0.0.0"}\n' > "${b}/proj/package.json"
    if [[ "${mode}" == run ]]; then
      printf '{"name":"proj","version":"0.0.0","dependencies":{"sdv":"1.0.0"}}\n' > "${b}/proj/package.json"
      printf '{"name":"sdv","version":"1.0.0","bin":{"sdv":"cli.sh"}}\n' > "${b}/proj/node_modules/sdv/package.json"
      printf '#!/bin/sh\necho ran > "%s/ran"\n' "${b}" > "${b}/proj/node_modules/sdv/cli.sh"
      chmod +x "${b}/proj/node_modules/sdv/cli.sh"
      ln -s ../sdv/cli.sh "${b}/proj/node_modules/.bin/sdv"
    fi
    (cd "${b}/proj" && timeout 20 "$@" < /dev/null > "${b}/out" 2>&1) || true
    case "${mode}" in
      install)
        if grep -q '"sdv"' "${b}/proj/package.json" || grep -q 'installed sdv@' "${b}/out"; then
          echo N
        elif grep -q '"sdw"' "${b}/proj/package.json" || grep -q 'installed sdw@' "${b}/out"; then
          echo V
        else
          echo X
        fi
        ;;
      update)
        if grep -q 'match "../sdv"' "${b}/out"; then echo N; else echo X; fi
        ;;
      run)
        if [[ -e "${b}/ran" ]] || grep -q 'package manifest sdv' "${b}/out"; then echo N; else echo X; fi
        ;;
    esac > "${b}/answer"
  }

  # <mode> <target index> <words after bun's own name...>, as `bun ...`.
  : > "${work}/bun.forms"
  while IFS= read -r o; do
    for c in add install; do
      printf 'install\t3\tbun\t%s\t%s\t../sdv\t../sdw\n' "${c}" "${o}" >> "${work}/bun.forms"
    done
    printf 'update\t3\tbun\tupdate\t%s\t../sdv\n' "${o}" >> "${work}/bun.forms"
    printf 'install\t3\tbun\t%s\tadd\t../sdv\n' "${o}" >> "${work}/bun.forms"
    printf 'run\t3\tbun\tx\t%s\tsdv\ta1\n' "${o}" >> "${work}/bun.forms"
    printf 'run\t2\tbunx\t%s\tsdv\ta1\n' "${o}" >> "${work}/bun.forms"
  done < "${work}/bun.options"

  while IFS=$'\t' read -r mode _ rest; do
    b="${work}/bun.${n}"
    mkdir -p "${b}"
    IFS=$'\t' read -r -a words <<< "${rest}"
    bun_form "${b}" "${mode}" "${words[@]}" &
    n=$((n + 1))
    (( n % 8 == 0 )) && wait
  done < "${work}/bun.forms"
  wait

  n=0
  while IFS=$'\t' read -r mode k rest; do
    IFS=$'\t' read -r -a words <<< "${rest}"
    answer=$(cat "${work}/bun.${n}/answer")
    # A form bun refuses or reads past says nothing about the option, so
    # only the forms where bun read the target either way are judged.
    judge bun "${answer}" "${k}" "${words[@]}"
    n=$((n + 1))
  done < "${work}/bun.forms"
  asked+=("bun ${version} ($(wc -l < "${work}/bun.options" | tr -d ' ') options, ${n} forms)")
}

ask_pip() {
  command -v python3 >/dev/null 2>&1 || return 3
  python3 -c 'import pip._internal.commands' 2>/dev/null || return 3
  local version line kind k answer
  version=$(python3 -c 'import pip; print(pip.__version__)')
  table_options pip | LC_ALL=C sort -u > "${work}/pip.table"
  # pip's answer for each form: in place (`pip install <opt> SDV SDW`) and
  # before the command (`pip <opt> install SDV`), for every option pip
  # defines, every table option and every prefix of a table option.
  python3 - "${work}/pip.table" > "${work}/pip.forms" 2>/dev/null <<'PY'
import sys, io, contextlib
from pip._internal.commands import create_command
from pip._internal.cli.main_parser import parse_command
table = [l.strip() for l in open(sys.argv[1]) if l.strip()]
parser = create_command("install").parser
opts = set()
for o in parser._get_all_options():
    opts.update(o._short_opts + o._long_opts)
words = set(opts) | set(table)
for t in table:
    if t.startswith("--"):
        for n in range(3, len(t)):
            words.add(t[:n])
def read(argv, pre):
    sink = io.StringIO()
    try:
        with contextlib.redirect_stderr(sink), contextlib.redirect_stdout(sink):
            if pre:
                name, args = parse_command(argv)
                if name != "install":
                    return "X"
            else:
                args = argv
            _, rest = create_command("install").parse_args(args)
    except BaseException:
        return "X"
    if "SDV" in rest:
        return "N"
    return "V" if "SDW" in rest or pre else "X"
for w in sorted(words):
    if w in ("-h", "--help", "-V", "--version"):
        continue
    print("in\t3\tpip\tinstall\t%s\tSDV\tSDW\t%s" % (w, read([w, "SDV", "SDW"], False)))
    print("pre\t3\tpip\t%s\tinstall\tSDV\t%s" % (w, read([w, "install", "SDV"], True)))
PY
  while IFS=$'\t' read -r kind k line; do
    answer="${line##*$'\t'}"
    line="${line%$'\t'*}"
    IFS=$'\t' read -r -a words <<< "${line}"
    judge pip "${answer}" "${k}" "${words[@]}"
  done < "${work}/pip.forms"
  asked+=("pip ${version} ($(wc -l < "${work}/pip.forms" | tr -d ' ') forms)")
}

ask_python() {
  command -v python3 >/dev/null 2>&1 || return 3
  python3 -m pip --version >/dev/null 2>&1 || return 3
  local version f a v answer n=0
  version=$(python3 --version 2>&1)
  : > "${work}/python.forms"
  # Clusters of the switches python reads, with -m last, -m alone, its module
  # attached, and the options that take a value before it.
  for a in b B d E I O P q s S u v x; do
    printf '%s\n' "-${a} -m pip" "-${a}m pip" "-${a}mpip" "-${a}${a}m pip" "-${a}W ignore -m pip" \
      "-${a}Wignore -m pip" "-${a}c pass -m pip" "-${a}X dev -m pip" >> "${work}/python.forms"
  done
  printf '%s\n' "-m pip" "-mpip" "-W ignore -m pip" "-Wignore -m pip" "-W -m pip" "-X -I -m pip" \
    "-Xdev -Im pip" "--check-hash-based-pycs always -m pip" "-c pass -m pip" "-sEm pip" \
    "-E -s -m pip" "-Im json.tool" "-I script.py -m pip" >> "${work}/python.forms"
  while IFS= read -r f; do
    # shellcheck disable=SC2086
    set -f; read -r -a words <<< "python3 ${f}"; set +f
    answer=X
    if (cd "${work}" && timeout 20 python3 "${words[@]:1}" --version < /dev/null 2>&1) | grep -q '^pip '; then
      answer=N
    fi
    judge python "${answer}" $(( ${#words[@]} + 1 )) "${words[@]}" install SDV
    n=$((n + 1))
  done < "${work}/python.forms"
  asked+=("${version} (${n} forms)")
}

# A clap help, as `<option> <N|V>` lines: V for a value it requires.
clap_options() {
  LC_ALL=C awk '
    /^[[:space:]]+-/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      n = split(line, t, /[[:space:]]+/)
      opts = ""; cls = "N"
      for (i = 1; i <= n; i++) {
        w = t[i]
        if (w ~ /^-[A-Za-z0-9],?$/ || w ~ /^--[A-Za-z0-9][A-Za-z0-9-]*,?$/) { sub(/,$/, "", w); opts = opts " " w; continue }
        if (w ~ /^--[A-Za-z0-9][A-Za-z0-9-]*(\.\.\.|\[)/) { sub(/[.[].*/, "", w); opts = opts " " w; break }
        if (w ~ /^<[^>]*>,?$/) { cls = "V"; continue }
        break
      }
      m = split(opts, o, " ")
      for (j = 1; j <= m; j++) print o[j], cls
    }'
}

# <family> <help file> <command words...>: the forms for one command, from
# its help and the table. An option the help does not print is refused.
ask_clap_command() {
  local family="$1" help="$2" o cls answer
  shift 2
  { awk '{ print $1 }' "${help}"; table_options "${family}"; } | LC_ALL=C sort -u | while IFS= read -r o; do
    [[ "${o}" != -h && "${o}" != --help && "${o}" != -V && "${o}" != --version ]] || continue
    cls=$(awk -v o="${o}" '$1 == o { print $2; exit }' "${help}")
    case "${cls}" in N) answer=N ;; V) answer=V ;; *) answer=X ;; esac
    printf '%s\t%s\n' "${answer}" "${o}"
  done > "${work}/clap.forms"
  while IFS=$'\t' read -r answer o; do
    judge "${family}" "${answer}" $(( $# + 1 )) "$@" "${o}" SDV SDW
  done < "${work}/clap.forms"
}

ask_uv() {
  command -v uv >/dev/null 2>&1 || return 3
  local version before="${forms}"
  version=$(uv --version | awk '{ print $2 }')
  uv add --help | clap_options > "${work}/uv.add"
  uv pip install --help | clap_options > "${work}/uv.pip"
  uv tool install --help | clap_options > "${work}/uv.tool"
  uv tool run --help | clap_options > "${work}/uv.run"
  ask_clap_command uv "${work}/uv.add" uv add
  ask_clap_command uv "${work}/uv.pip" uv pip install
  ask_clap_command uv "${work}/uv.tool" uv tool install
  ask_clap_command uv "${work}/uv.run" uv tool run
  ask_clap_command uvx "${work}/uv.run" uvx
  # Before the command, only a global option is read, with its own arity.
  uv --help | clap_options > "${work}/uv.global"
  while IFS=' ' read -r o cls; do
    [[ "${cls}" == N && "${o}" != -h && "${o}" != --help && "${o}" != -V && "${o}" != --version ]] || continue
    judge uv N 3 uv "${o}" add SDV
  done < "${work}/uv.global"
  asked+=("uv ${version} ($(( forms - before )) forms)")
}

ask_cargo() {
  command -v cargo >/dev/null 2>&1 || return 3
  local version before="${forms}"
  version=$(cargo --version | awk '{ print $2 }')
  cargo install --help | clap_options > "${work}/cargo.install"
  cargo add --help | clap_options > "${work}/cargo.add"
  ask_clap_command cargo "${work}/cargo.install" cargo install
  ask_clap_command cargo "${work}/cargo.add" cargo add
  cargo --help | clap_options > "${work}/cargo.global"
  while IFS=' ' read -r o cls; do
    [[ "${cls}" == N && "${o}" != -h && "${o}" != --help && "${o}" != -V && "${o}" != --version ]] || continue
    judge cargo N 3 cargo "${o}" install SDV
  done < "${work}/cargo.global"
  asked+=("cargo ${version} ($(( forms - before )) forms)")
}

ask_go() {
  command -v go >/dev/null 2>&1 || return 3
  local version before="${forms}" c o cls
  version=$(go version | awk '{ print $3 }')
  # go's flag package: a flag the help prints with an argument takes one.
  go help build | LC_ALL=C awk '/^\t-[a-z]/ { sub(/^\t/, ""); print $1, (NF > 1 ? "V" : "N") }' > "${work}/go.build"
  printf '%s\n' '-t N' '-u N' '-tool N' >> "${work}/go.get"
  cat "${work}/go.build" >> "${work}/go.get"
  cp "${work}/go.build" "${work}/go.run"
  go help run | grep -q -- '-exec xprog' && printf '%s\n' '-exec V' >> "${work}/go.run"
  for c in get install run; do
    [[ -e "${work}/go.${c}" ]] || cp "${work}/go.build" "${work}/go.${c}"
    { awk '{ print $1 }' "${work}/go.${c}"; table_options go; } | LC_ALL=C sort -u | while IFS= read -r o; do
      cls=$(awk -v o="${o}" '$1 == o { print $2; exit }' "${work}/go.${c}")
      printf '%s\t%s\n' "${cls:-X}" "${o}"
    done > "${work}/go.forms"
    while IFS=$'\t' read -r cls o; do
      judge go "${cls}" 3 go "${c}" "${o}" example.com/sdv@v1.0.0 example.com/sdw@v1.0.0
    done < "${work}/go.forms"
  done
  asked+=("go ${version} ($(( forms - before )) forms)")
}

for f in "${families[@]}"; do
  rc=0
  "ask_${f}" || rc=$?
  case "${rc}" in
    0) ;;
    3) skipped+=("${f}") ;;
    *) printf 'could not ask %s (exit %s)\n' "${f}" "${rc}" >&2; exit 2 ;;
  esac
done
for f in pnpm yarn pipx poetry pipenv gem bundle dotnet mvn; do
  skipped+=("${f} (not asked here)")
done

printf 'asked: %s\n' "${asked[*]:-none}"
printf 'skipped: %s\n' "${skipped[*]}"
printf '%s forms, %s where the grammar reads a value the manager does not take (OVER), %s where it checks a value as a package (UNDER, not a failure)\n' \
  "${forms}" "${over}" "${under}"
(( over == 0 )) || exit 1
(( ${#asked[@]} > 0 )) || exit 3
exit 0
