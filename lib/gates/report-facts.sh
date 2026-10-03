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

# How many cp or rm runs this rollback made. A cp or rm that fails can still
# have changed the path (rm -rf removes what it can, cp truncates before it
# writes), so "The rollback changed nothing." is said only where none ran.
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
# untouched. A target that is there and is not a regular file is not copied
# onto: cp into a directory writes a file inside it and exits 0, and the
# rollback wrote a file in the project that no line named (CP2).
did_restore() {
  local rc=0
  if [[ -e "$2" && ! -L "$2" && ! -f "$2" ]]; then
    report_say "not restored $2: $2 exists and is not a regular file"
    return 0
  fi
  REPORT_CHANGED=$((REPORT_CHANGED + 1))
  cp "$1" "$2" 2>/dev/null || rc=$?
  if report_same_bytes "$1" "$2"; then
    report_say "restored $2"
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
  REPORT_CHANGED=$((REPORT_CHANGED + 1))
  rm -rf "$1" 2>/dev/null || rc=$?
  if [[ -e "$1" || -L "$1" ]]; then
    report_say "not removed $1: rm exit ${rc}; $(fact_path "$1")"
  else
    report_say "removed $1"
  fi
}

# did_refuse <restore|removal> <path> <fact>: prints the line. The fact is the
# reason the caller's own check returned (rollback_target_outside).
did_refuse() { printf 'refused %s of %s: %s' "$1" "$2" "$3"; }

# report_changed_nothing: said when no step of this rollback ran cp or rm.
report_changed_nothing() {
  [[ ${REPORT_CHANGED} -gt 0 ]] || report_say "The rollback changed nothing."
}

# Whether the install ran without its scripts is two observations, and only
# what was observed is said: the pre-guard's own record that it asked for
# --ignore-scripts, and the command this hook received. A runtime that does not
# apply the rewrite leaves the first true and the second false, and "safedeps
# added" was said there on the record alone.
#
# "The command carries it" was a substring test, so `--ignore-scripts=false`,
# an `echo --ignore-scripts` after the install and a `# --ignore-scripts`
# comment each read as carrying it while the install ran its scripts (F2,
# bamdori r16). So the command is read for it, and it has three answers:
#
#   carries  every npm install statement's own words make npm read
#            ignore-scripts as true, spelled `--ignore-scripts` or
#            `--ignore-scripts=true`;
#   lacks    no word of the command can be read as that option, or every npm
#            install statement's words set it to false (`--ignore-scripts=false`)
#            or leave it out;
#   unread   anything else, and then the line says safedeps did not tell.
#
# The one lexer of the command lives in the pre-guard, and a second parser is
# what the install grammar forbids. So statements are read here only where the
# shell has nothing to decide: no quotes, no expansion, no comment, no heredoc,
# nothing but plain words, `;` `&&` `||` `|` `&`, newlines and plain
# redirections. The option is read with the install grammar's reading of npm's
# words (safedeps_npm_read_args, measured against npm), and where the other
# npm defines an option differently both readings must agree.

# A word npm could read as ignore-scripts: an option word that holds "ig"
# (`--ig` abbreviates it, `--no-ignore-scripts` negates it).
report_ig_word() { [[ "$1" =~ ^-.*[Ii][Gg] ]]; }

# report_npm_ignore_scripts_once <words after npm>: set | false | unset |
# other (not an install) | unknown.
report_npm_ignore_scripts_once() {
  local -a w=("$@") flagged=()
  local k f entry at key val want="" spelled
  safedeps_npm_read_args "$@" || { printf 'unknown'; return 0; }
  (( ${#SAFEDEPS_G_NPM_WORDS[@]} > 0 )) || { printf 'other'; return 0; }
  safedeps_npm_kind_of "${SAFEDEPS_G_NPM_WORDS[0]}"
  case "${SAFEDEPS_G_NPM_KIND}" in install|link) ;; *) printf 'other'; return 0 ;; esac
  for (( k = 0; k < ${#w[@]}; k++ )); do
    report_ig_word "${w[k]}" && flagged+=("${k}")
  done
  (( ${#flagged[@]} > 0 )) || { printf 'unset'; return 0; }
  for f in "${flagged[@]}"; do
    case "${w[f]}" in
      --ignore-scripts|--ignore-scripts=true) spelled=true ;;
      --ignore-scripts=false) spelled=false ;;
      *) printf 'unknown'; return 0 ;;
    esac
    [[ -z "${want}" || "${want}" == "${spelled}" ]] || { printf 'unknown'; return 0; }
    want="${spelled}"
    # A word npm read as a positional is not the option.
    for at in "${SAFEDEPS_G_NPM_AT[@]+"${SAFEDEPS_G_NPM_AT[@]}"}"; do
      [[ "${at}" != "${f}" ]] || { printf 'unknown'; return 0; }
    done
  done
  for entry in "${SAFEDEPS_G_NPM_VALUES[@]+"${SAFEDEPS_G_NPM_VALUES[@]}"}"; do
    at="${entry%%$'\037'*}" entry="${entry#*$'\037'}" key="${entry%%$'\037'*}" val="${entry#*$'\037'}"
    for f in "${flagged[@]}"; do
      [[ "${at}" == "${f}" ]] || continue
      # Another option took the word as its value, or the value is not the one
      # the spelling names (`--ignore-scripts false`).
      [[ "${key}" == ignore-scripts && "${val}" == "${want}" ]] || { printf 'unknown'; return 0; }
    done
    if [[ "${key}" == ignore-scripts && "${val}" != "${want}" ]]; then
      printf 'unknown'; return 0
    fi
  done
  [[ "${want}" == true ]] && printf 'set' || printf 'false'
}

report_npm_ignore_scripts() {
  local one other
  one=$(report_npm_ignore_scripts_once "$@")
  if safedeps_npm_other_applies "$@"; then
    other=$(safedeps_npm_as_other report_npm_ignore_scripts_once "$@")
    [[ "${other}" == "${one}" ]] || { printf 'unknown'; return 0; }
  fi
  printf '%s' "${one}"
}

# report_command_statements <command>: the statements of a command the shell
# has nothing to decide in, one per line, words separated by \037, with
# redirections taken out. Returns 1 for any other command.
report_command_statements() {
  local rest="$1" cur="" redir=0 tok
  local re_plain=$'^[A-Za-z0-9@%+,./:=^_~ \t\n;&|<>-]*$'
  local re_blank=$'^[ \t]+' re_sep=$'^(&&|[|][|]|;|[|]|&|\n)'
  local re_redir='^[0-9]*(&>>|&>|>>|>&|<&|>|<)' re_word=$'^[^ \t\n;&|<>]+'
  [[ "${rest}" =~ ${re_plain} ]] || return 1
  while [[ -n "${rest}" ]]; do
    if [[ "${rest}" =~ ${re_blank} ]]; then
      rest="${rest:${#BASH_REMATCH[0]}}"
    elif [[ "${rest}" =~ ${re_redir} ]]; then
      (( redir == 0 )) || return 1
      redir=1 rest="${rest:${#BASH_REMATCH[0]}}"
    elif [[ "${rest}" =~ ${re_sep} ]]; then
      (( redir == 0 )) || return 1
      tok="${BASH_REMATCH[0]}" rest="${rest:${#BASH_REMATCH[0]}}"
      if [[ -n "${cur}" ]]; then
        printf '%s\n' "${cur}"
        cur=""
      elif [[ "${tok}" != $'\n' ]]; then
        return 1
      fi
    elif [[ "${rest}" =~ ${re_word} ]]; then
      tok="${BASH_REMATCH[0]}" rest="${rest:${#BASH_REMATCH[0]}}"
      # zsh expands a word that starts with `=` to a command's path.
      [[ "${tok}" != =* ]] || return 1
      if (( redir )); then
        redir=0
      else
        cur+="${cur:+$'\037'}${tok}"
      fi
    else
      return 1
    fi
  done
  (( redir == 0 )) || return 1
  [[ -z "${cur}" ]] || printf '%s\n' "${cur}"
}

# fact_command_ignore_scripts <command>: carries | lacks | unread
fact_command_ignore_scripts() {
  local text="$1" bare statements line verdict set=0 lack=0 k
  local re_expands='[$`*?[{]'
  local -a w=()
  # A backslash before a newline joins the lines (the backslash must be quoted
  # in the pattern, or it escapes the newline instead).
  text="${text//\\$'\n'/}"
  bare="${text//[\'\"\\]/}"
  if [[ ! "${text}" =~ ${re_expands} && ! "${bare}" =~ [Ii][Gg] ]]; then
    printf 'lacks'
    return 0
  fi
  declare -F safedeps_npm_read_args >/dev/null || { printf 'unread'; return 0; }
  statements=$(report_command_statements "${text}") || { printf 'unread'; return 0; }
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    IFS=$'\037' read -r -a w <<< "${line}"
    k=0
    while (( k < ${#w[@]} )) && [[ "${w[k]}" =~ ^[A-Za-z_][A-Za-z0-9_]*[+]?= ]]; do k=$(( k + 1 )); done
    if (( k < ${#w[@]} )) && [[ "${w[k]}" == npm ]]; then
      verdict=$(report_npm_ignore_scripts "${w[@]:k+1}")
      case "${verdict}" in
        set) set=$(( set + 1 )) ;;
        false|unset) lack=$(( lack + 1 )) ;;
        other) ;;
        *) printf 'unread'; return 0 ;;
      esac
    else
      # An npm this reading does not start a statement with (`command npm`,
      # `./npm`, `time npm`) is not read.
      for (( ; k < ${#w[@]}; k++ )); do
        [[ ! "${w[k]}" =~ (^|[/=])npm$ ]] || { printf 'unread'; return 0; }
      done
    fi
  done <<< "${statements}"
  if (( set > 0 && lack == 0 )); then
    printf 'carries'
  elif (( lack > 0 && set == 0 )); then
    printf 'lacks'
  else
    printf 'unread'
  fi
}

# fact_inert <meta file> <command>
fact_inert() {
  local asked=false carried
  [[ "$(jq -r '.ignore_scripts_injected == true' "$1" 2>/dev/null)" == true ]] && asked=true
  carried=$(fact_command_ignore_scripts "$2")
  case "${asked}:${carried}" in
    true:carries) printf 'safedeps added --ignore-scripts to this install' ;;
    true:lacks) printf 'safedeps asked for --ignore-scripts on this install; the command this hook received does not carry it' ;;
    true:*) printf 'safedeps asked for --ignore-scripts on this install and did not tell whether the command this hook received carries it' ;;
    false:carries) printf 'safedeps did not add --ignore-scripts to this install; the command this hook received carries it' ;;
    false:lacks) printf 'safedeps did not add --ignore-scripts to this install; the command this hook received does not carry it' ;;
    *) printf 'safedeps did not add --ignore-scripts to this install and did not tell whether the command this hook received carries it' ;;
  esac
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
