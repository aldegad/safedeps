#!/usr/bin/env bash
# safedeps: the locale a test host runs a run under, as scripts/ci/remote.sh
# picks it.
#
#   scripts/test/host-locale.sh [--script <remote.sh>]
#
# `remote.sh prepare` picks the locale for the build and every unit of a run
# from the host's own list. It writes the pick to out/locale and how it picked
# it to out/locale.pick, the line run.txt quotes for the host. Each row gives
# prepare a host of its own: a `locale` found ahead of the real one on PATH
# lists the row's names for `locale -a`, and answers `locale charmap` for each
# name as the row says, on standard output, on standard error and in its exit
# status. The row then reads both files. The answers have the shapes hosts
# give. macOS answers with what follows the dot in the name: UTF-8@latin for
# sr_RS.UTF-8@latin and an empty line for en_NZ. It answers US-ASCII, with no
# warning, for a name it cannot load. glibc lists its codesets in lower case
# (de_DE.utf8), and a name need not carry a codeset at all (en_IN).
#
# The build that prepare starts is a stub: the run's tree holds a remote.sh
# that exits at once, so nothing past the pick runs. With --script the rows
# judge another copy of remote.sh, as the red controls do: the copy before
# every name was judged by its charmap passed over sr_RS.UTF-8@latin, and
# wrote no out/locale.pick.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="${ROOT_DIR}/scripts/ci/remote.sh"
if [[ "${1:-}" == --script ]]; then
  [[ -f "${2:-}" ]] || { printf 'usage: %s [--script <remote.sh>]\n' "$0" >&2; exit 2; }
  script="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
fi
failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-host-locale.XXXXXX") || exit 2
trap 'rm -rf "${tmp_root}"' EXIT

# The host's `locale`. Each line of the row's file is name|answer|warning|exit
# status. An answer of - prints nothing, and \n in an answer starts another
# line. A name the file does not hold is answered US-ASCII, as macOS answers a
# name it cannot load. sh, not bash: bash warns on standard error when it
# starts under an LC_ALL its system cannot load, and every answer here is given
# under the LC_ALL of the name asked about.
fake_bin="${tmp_root}/bin"
mkdir -p "${fake_bin}"
cat > "${fake_bin}/locale" <<'FAKE'
#!/bin/sh
rows=${HOST_LOCALE_ROWS:?}
case "$1" in
  -a)
    [ ! -e "${rows}.fails" ] || { echo 'locale: cannot read the locale directory' >&2; exit 1; }
    while IFS='|' read -r name answer warning status; do
      printf '%s\n' "${name}"
    done < "${rows}"
    ;;
  charmap)
    while IFS='|' read -r name answer warning status; do
      [ "${name}" = "${LC_ALL-}" ] || continue
      [ "${answer}" = - ] || printf '%b\n' "${answer}"
      [ -z "${warning}" ] || printf '%s\n' "${warning}" >&2
      exit "${status}"
    done < "${rows}"
    printf 'US-ASCII\n'
    ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "${fake_bin}/locale"

# The record's three forms, as scripts/ci/remote.sh writes them.
picked() { # name answer examined listed
  printf 'picked %s (locale charmap: %s), after examining %s of the %s names locale -a lists' "$1" "$2" "$3" "$4"
}
no_utf8() { # listed
  printf 'C, since no name is UTF-8: all %s names locale -a lists were examined, each answered another charmap, and none says UTF-8' "$1"
}
none_fit() { # listed, then how many say UTF-8 but answered another charmap, gave no single clean answer, answered UTF-8 with a name not carried
  printf 'C, since none fit: all %s names locale -a lists were examined and none was taken; %s say UTF-8 but answered another charmap, %s gave no single clean answer, %s answered UTF-8 but have a name the run does not carry' \
    "$1" "$2" "$3" "$4"
}

# prepare_host: runs `remote.sh prepare` on the host the lines on standard
# input describe, in a run directory of its own, and leaves it in $run, its
# output in $run.out and its exit status in $rc. $1 makes `locale -a` fail.
prepare_host() {
  local dir
  run="${tmp_root}/none" rc=99
  dir=$(mktemp -d "${tmp_root}/row.XXXXXX") || return
  cat > "${dir}/rows"
  [[ "${1:-}" != fails ]] || : > "${dir}/rows.fails"
  run="${dir}/run"
  mkdir -p "${run}/tree/scripts/ci"
  printf 'exit 0\n' > "${run}/tree/scripts/ci/remote.sh"
  ( cd "${dir}" || exit 2
    unset LANG "${!LC_@}"
    HOST_LOCALE_ROWS="${dir}/rows" PATH="${fake_bin}:${PATH}" bash "${script}" prepare "${run}" 1 ) > "${run}.out" 2>&1
  rc=$?
}

# row LABEL LOCALE HOW: the pick and the record for the host on standard input.
row() {
  local label="$1" want="$2" want_how="$3" got how
  prepare_host
  if (( rc != 0 )); then
    fail "${label}: prepare ended ${rc}: $(head -c 200 "${run}.out")"
    fail "${label}: no record of the pick"
    return
  fi
  got=$(cat "${run}/out/locale" 2>/dev/null) || got="(no out/locale)"
  if [[ "${got}" == "${want}" ]]; then pass "${label}: picks ${want}"; else fail "${label}: picks ${want}, got ${got}"; fi
  how=$(cat "${run}/out/locale.pick" 2>/dev/null) || how="(no out/locale.pick)"
  if [[ "${how}" == "${want_how}" ]]; then
    pass "${label}: says '${want_how}'"
  else
    fail "${label}: says '${want_how}', got '${how}'"
  fi
}

# --- the three lists a validator gave --------------------------------------------------
row "C and POSIX alone" C "$(no_utf8 2)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
EOF
row "with sr_RS.UTF-8" sr_RS.UTF-8 "$(picked sr_RS.UTF-8 UTF-8 3 3)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
sr_RS.UTF-8|UTF-8||0
EOF
row "with sr_RS.UTF-8@latin" sr_RS.UTF-8@latin "$(picked sr_RS.UTF-8@latin UTF-8 3 3)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
sr_RS.UTF-8@latin|UTF-8||0
EOF

# --- names a UTF-8 locale is listed under ----------------------------------------------
row "sr_RS.UTF-8@latin as macOS answers it" sr_RS.UTF-8@latin "$(picked sr_RS.UTF-8@latin UTF-8@latin 3 3)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
sr_RS.UTF-8@latin|UTF-8@latin||0
EOF
row "a modifier after UTF-8 (@euro)" de_DE.UTF-8@euro "$(picked de_DE.UTF-8@euro UTF-8 3 3)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
de_DE.UTF-8@euro|UTF-8||0
EOF
row "glibc's utf8 with a modifier" ca_ES.utf8@valencia "$(picked ca_ES.utf8@valencia UTF-8 3 3)" <<'EOF'
C|ANSI_X3.4-1968||0
POSIX|ANSI_X3.4-1968||0
ca_ES.utf8@valencia|UTF-8||0
EOF
row "glibc's utf8" de_DE.utf8 "$(picked de_DE.utf8 UTF-8 3 3)" <<'EOF'
C|ANSI_X3.4-1968||0
POSIX|ANSI_X3.4-1968||0
de_DE.utf8|UTF-8||0
EOF
row "an answer spelled utf8" de_DE.utf8 "$(picked de_DE.utf8 utf8 3 3)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
de_DE.utf8|utf8||0
EOF
row "a name with no codeset whose charmap is UTF-8" en_IN "$(picked en_IN UTF-8 3 3)" <<'EOF'
C|ANSI_X3.4-1968||0
POSIX|ANSI_X3.4-1968||0
en_IN|UTF-8||0
EOF

# --- names that say UTF-8 and are not taken ------------------------------------------------
row "a name that says UTF-8 answered US-ASCII" C "$(none_fit 3 1 0 0)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
xx_XX.UTF-8|US-ASCII||0
EOF
row "an answer of UTF-8 with a warning" C "$(none_fit 3 0 1 0)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
fr_FR.UTF-8|UTF-8|locale: Cannot set LC_CTYPE to default locale: No such file or directory|0
EOF
row "a charmap that fails" C "$(none_fit 3 0 1 0)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
ja_JP.UTF-8|-|locale: cannot load|1
EOF
row "an answer of two lines" C "$(none_fit 3 0 1 0)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
ko_KR.UTF-8|UTF-8\nUTF-8||0
EOF
row "an empty answer" C "$(none_fit 3 0 1 0)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
en_NZ|||0
EOF
row "a UTF-8 name the run does not carry" C "$(none_fit 3 0 0 1)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
nb_NO.UTF-8+x|UTF-8||0
EOF
row "every way not to take a name, counted apart" C "$(none_fit 6 1 2 1)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
xx_XX.UTF-8|US-ASCII||0
en_NZ|||0
ja_JP.UTF-8|-|locale: cannot load|1
nb_NO.UTF-8+x|UTF-8||0
EOF
row "a carried UTF-8 name after one that is not" nb_NO.UTF-8 "$(picked nb_NO.UTF-8 UTF-8 4 4)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
nb_NO.UTF-8+x|UTF-8||0
nb_NO.UTF-8|UTF-8||0
EOF

# --- order ---------------------------------------------------------------------------------
row "en_US.UTF-8 before the names listed ahead of it" en_US.UTF-8 "$(picked en_US.UTF-8 UTF-8 1 4)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
af_ZA.UTF-8|UTF-8||0
en_US.UTF-8|UTF-8||0
EOF
row "glibc's C.utf8 before the names listed after it" C.utf8 "$(picked C.utf8 UTF-8 1 4)" <<'EOF'
C|ANSI_X3.4-1968||0
C.utf8|UTF-8||0
POSIX|ANSI_X3.4-1968||0
aa_DJ.utf8|UTF-8||0
EOF
row "a preferred name whose charmap is not UTF-8" de_DE.UTF-8 "$(picked de_DE.UTF-8 UTF-8 4 4)" <<'EOF'
C.UTF-8|US-ASCII||0
C|US-ASCII||0
POSIX|US-ASCII||0
de_DE.UTF-8|UTF-8||0
EOF

# --- hosts with no UTF-8 -------------------------------------------------------------------
row "names of other charmaps only" C "$(no_utf8 3)" <<'EOF'
C|US-ASCII||0
POSIX|US-ASCII||0
en_US.ISO8859-1|ISO8859-1||0
EOF
row "an empty list" C "$(no_utf8 0)" < /dev/null

prepare_host fails < /dev/null
if (( rc == 2 )) && grep -q 'cannot list the host.s locales' "${run}.out" && [[ ! -e "${run}/out/locale" ]]; then
  pass "a locale -a that fails fails the preparation, and no locale is recorded"
else
  fail "a locale -a that fails fails the preparation (rc ${rc}: $(head -c 200 "${run}.out"))"
fi

(( failures == 0 )) || { printf '# %d row(s) failed\n' "${failures}"; exit 1; }
