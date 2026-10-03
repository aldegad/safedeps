#!/usr/bin/env bash
# The lines a rollback, a refused step, a skipped rebuild and the
# unfinished-rollback report say.
#
# Every such line is printed by one of these functions, and each function runs
# its own check when it is called and prints what that check returned. So no
# line exists without a check behind it. A line states a path and what a test
# of it returned, an exit status, or one of safedeps' own acts. It never says
# what a path contains, why something happened, what npm would do, or what the
# reader should do next: those were the clauses that turned out false, three
# review rounds in a row, each one attached behind a fact that was true.
#
# The set of line forms is closed. scripts/test/e2e.sh holds the same set as
# anchored patterns, reads every line the hooks print against it, and checks
# each line's claim again on disk. A new line needs a function here and a form
# there, with the check that proves it.
#
# Needs safedeps_link_target (lib/gates/npm-reach.sh).

# The lines of this run, in the order they were said. The effect gate's own
# warnings share the array; they are prose, and their forms are not in this
# file.
report_say() { ROLLBACK_WARNINGS+=("$1"); }

# How many paths this rollback wrote or removed.
REPORT_CHANGED=0

report_same_bytes() {
  if command -v cmp >/dev/null 2>&1; then
    cmp -s "$1" "$2"
  else
    diff -q "$1" "$2" >/dev/null 2>&1
  fi
}

# fact_path <path>: "<path> is a symbolic link to <physical path>" |
# "<path> exists" | "<path> does not exist", from a test run here.
fact_path() {
  if [[ -L "$1" ]]; then
    printf '%s is a symbolic link to %s' "$1" "$(safedeps_link_target "$1")"
  elif [[ -e "$1" ]]; then
    printf '%s exists' "$1"
  else
    printf '%s does not exist' "$1"
  fi
}
report_path() { report_say "$(fact_path "$1")"; }

# fact_outside <project dir> <target>: prints why a rollback must not write or
# remove <target>, or nothing when it may. Every target is a name directly
# inside the project, so it can lead outside only by being a link.
fact_outside() {
  if ! (cd -P "$1" 2>/dev/null); then
    printf 'the project directory %s cannot be resolved' "$1"
  elif [[ -L "$2" ]]; then
    fact_path "$2"
  fi
}

# report_workspaces_key <dir>: one line when <dir>/package.json is an object
# with the key, nothing otherwise. It names the key, not what npm reads in it.
report_workspaces_key() {
  if jq -e 'type == "object" and has("workspaces")' "$1/package.json" >/dev/null 2>&1; then
    report_say "$1/package.json has the key workspaces"
  fi
}

# fact_file <label> <path>: names a record file, after looking for it.
fact_file() {
  if [[ -f "$2" ]]; then
    printf '%s: %s' "$1" "$2"
  else
    printf '%s: %s is not a file' "$1" "$2"
  fi
}

# did_restore <snapshot file> <target>: copies, then compares. A copy that
# fails is a line, not the end of the rollback: under `set -e` a bare cp ended
# the hook there, with the lockfile still the rejected one and node_modules
# untouched.
did_restore() {
  local rc=0
  cp "$1" "$2" 2>/dev/null || rc=$?
  if report_same_bytes "$1" "$2"; then
    report_say "restored $2"
    REPORT_CHANGED=$((REPORT_CHANGED + 1))
  elif [[ -e "$2" || -L "$2" ]]; then
    report_say "not restored $2: cp exit ${rc}; $2 differs from the snapshot"
  else
    report_say "not restored $2: cp exit ${rc}; $2 does not exist"
  fi
}

# did_remove <path>: removes, then looks. rm -rf removes what it can and exits
# non-zero over the rest, so the line says the path is still there and nothing
# about what is left in it.
did_remove() {
  local rc=0
  rm -rf "$1" 2>/dev/null || rc=$?
  if [[ -e "$1" || -L "$1" ]]; then
    report_say "not removed $1: rm exit ${rc}; $(fact_path "$1")"
  else
    report_say "removed $1"
    REPORT_CHANGED=$((REPORT_CHANGED + 1))
  fi
}

# did_refuse <restore|removal> <path> <fact>: prints the line. The fact is the
# reason the caller's own check returned (rollback_target_outside).
did_refuse() { printf 'refused %s of %s: %s' "$1" "$2" "$3"; }

# report_changed_nothing: said when no step of this rollback wrote or removed.
report_changed_nothing() {
  [[ ${REPORT_CHANGED} -gt 0 ]] || report_say "The rollback changed nothing."
}

# Whether the install ran without its scripts is two observations, and only
# what was observed is said: the pre-guard's own record that it asked for
# --ignore-scripts, and the command this hook received. A runtime that does not
# apply the rewrite leaves the first true and the second false, and "safedeps
# added" was said there on the record alone.
#
# fact_inert <meta file> <command>
fact_inert() {
  local asked=false carried=false
  [[ "$(jq -r '.ignore_scripts_injected == true' "$1" 2>/dev/null)" == true ]] && asked=true
  [[ "$2" == *--ignore-scripts* ]] && carried=true
  if [[ "${asked}" == true && "${carried}" == true ]]; then
    printf 'safedeps added --ignore-scripts to this install'
  elif [[ "${asked}" == true ]]; then
    printf 'safedeps asked for --ignore-scripts on this install; the command this hook received does not carry it'
  elif [[ "${carried}" == true ]]; then
    printf 'safedeps did not add --ignore-scripts to this install; the command this hook received carries it'
  else
    printf 'safedeps did not add --ignore-scripts to this install; the command this hook received does not carry it'
  fi
}

# The rebuild after an install the pre-guard asked to be inert.
#
# did_not_rebuild <meta file> <command> <fact>
# did_rebuild <meta file> <command> <exit status>
report_rebuild() {
  local inert
  inert=$(fact_inert "$1" "$2")
  if [[ "${inert}" == 'safedeps added --ignore-scripts to this install' ]]; then
    report_say "${inert} and $3"
  else
    report_say "${inert}"
    report_say "safedeps $3"
  fi
}
did_not_rebuild() { report_rebuild "$1" "$2" "did not run npm rebuild: $3"; }
did_rebuild() { report_rebuild "$1" "$2" "ran npm rebuild: exit $3"; }
