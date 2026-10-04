#!/usr/bin/env bash
# safedeps: scan-failure census -- fail every reading of a command, one at a
# time and all at once, and check that no verdict gets weaker.
#
# The pre-guard reads a command through awk (the scanner, the line joiner, the
# blanking pass beside a visible install). A failed awk returns empty text, and
# empty text reads as "no install", so every reading is a place where a failure
# could turn a deny into a pass. The guard's answer to that is one gate that
# every non-deny path crosses after its last reading: if any reading failed, a
# command that names a package manager is denied as UNDECIDED. This census is
# how that claim is measured rather than argued. Three review rounds found
# weakenings that a list of hand-picked failure cases missed, because the
# cases were picked by the same reasoning that wrote the code.
#
# For each command it first runs the guard with nothing failing and counts the
# readings (N). Then it runs it again with the K-th reading failing, for every
# K in 1..N, and with readings K..N failing, and with every reading of one kind
# failing, and with every awk, every grep or every sed failing. grep and sed get
# a K-th mode of their own: a counting run finds how many times the guard calls
# each (G and S), and then each call fails alone, K in 1..G and 1..S. Each run
# is compared with the clean one on (decision, finding-or-UNDECIDED,
# updatedInput, pending record: project_dir, whether an npm trace was wanted,
# npm_unattributable).
#
#   same        identical to the clean run
#   undecided   denied as UNDECIDED -- the gate did its job
#   weakened    any other difference read from a failed call: a deny became
#               allow/pass, the inert rewrite was lost or moved, the pending
#               record changed. A changed record counts in either direction,
#               because the census cannot tell which one the PostToolUse hook
#               is better off with; only the gate's UNDECIDED settles a failure.
#   mislabeled  a deny that claims a finding, read from a failed reading
#   error       the hook exited non-zero
#
# and two ordering invariants are counted on every run, clean ones included:
#
#   after-gate      a reading that ran after the gate had passed
#   pending-on-deny a denied command that left pending state behind
#
# and one check on the census itself:
#
#   idle-mode       a failure mode that failed no call in any run. Its rows are
#                   all "same", which reads as a clean result and is none: the
#                   flag mode once keyed on a marker the guard did not carry.
#   unmarked        a clean run called awk with no `safedeps:` marker line. The
#                   census can fail only what it can name, so a reading without
#                   a marker is one it never fails, and its silence would read
#                   as a pass. Twice a hand-kept list of marked readings missed
#                   one, and the census reported zero over it (caught in review).
#   unlisted        a clean run called awk with a `safedeps:` marker the shim
#                   has no kind for: named, and still never failed.
#   unstable        a failing run that failed no call and still answered
#                   differently from its clean run. Nothing was injected, so
#                   the difference is the guard's own: in practice a run over
#                   1KB that met the self-budget deadline on a loaded machine,
#                   on one side and not the other. It used to be counted as
#                   mislabeled or weakened, which names a defect that was not
#                   there; the case's comparison is void instead, and says so.
#
# Exit status is 0 only when weakened, mislabeled, error, after-gate,
# pending-on-deny, idle-mode, unmarked, unlisted and unstable are all zero.
#
# Every payload is judged, never executed. Runs happen with PATH led by an awk
# shim that fails on cue; the guard keys each reading with a marker line in its
# awk program (`safedeps:<function>`), and the shim reads that marker. grep and
# sed carry no marker, so their shims count calls instead: the K-th call is the
# K-th grep (or sed) the run makes, whatever site makes it.
#
# Usage:
#   scripts/measure/scan-failure-census.sh [--quick] [--jobs N] [--variants "claude codex padded"]
#
#   --quick      the subset npm test runs (the corpus's "quick" block)
#   --jobs N     parallel runs (default: SAFEDEPS_TEST_JOBS when it is set,
#                otherwise half the CPUs rounded up, at most 16)
#   --variants   payload shapes: claude (no turn_id), codex (turn_id, so no
#                inert rewrite), padded (over 1KB, so the self-budget child
#                judges it), approved (claude, against a ledger that approves
#                the corpus's specs, so installs reach the allow path instead
#                of the ledger deny). Default: all four on every fifth command,
#                claude and approved on the rest; with --quick, all four on
#                the rows the corpus lists under quick.variants, claude on the
#                rest.
#
# --quick also skips the K-onward runs (the full census keeps them), so npm
# test pays for one failing run per reading rather than two. It keeps the K-th
# sed runs: sed-all fails the first judgment sed a command reaches and that
# mark covers every later one, so only a sed failing alone shows whether a
# later site marks its own failure. It skips the K-th grep runs, which the
# full census keeps: they were 1,126 of the quick corpus's 5,083 failing runs,
# and npm test is already long.
# The two grep sites they found (0240b78) are held by rows in
# scripts/test/scan-contract.sh that fail each of those calls alone.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SELF="${ROOT_DIR}/scripts/measure/scan-failure-census.sh"
CORPUS="${ROOT_DIR}/scripts/measure/scan-failure-corpus.json"

# --- one run (re-entered through xargs) -----------------------------------------
if [[ "${1:-}" == "--run" ]]; then
  WORK="$2" n="$3" mode="$4" k="$5"
  T=$(mktemp -d "${WORK}/run.XXXXXX")
  mkdir -p "${T}/p" "${T}/h" "${T}/st"
  printf '{"dependencies":{}}\n' > "${T}/p/package.json"
  # An .npmrc that changes nothing, so every npm install reads it and the
  # .npmrc reader is one of the readings failed. Without the file that reader
  # never runs, and its failure mode would be idle.
  printf 'fund=false\n' > "${T}/p/.npmrc"
  variant=$(cat "${WORK}/cases/${n}.variant")
  [[ "${variant}" != "approved" ]] || cp -R "${WORK}/approved-home" "${T}/h/safe"
  codex=""
  [[ "${variant}" == "codex" ]] && codex=1
  # The grep and sed shims are on PATH only in the modes that count or fail
  # them; in every other mode they would only exec the real tool (see setup).
  bin="${WORK}/bin"
  case "${mode}" in
    grep-all|grep-k) bin="${WORK}/bin-grep" ;;
    sed-all|sed-k) bin="${WORK}/bin-sed" ;;
    count) bin="${WORK}/bin-count" ;;
  esac
  rc=0
  out=$(jq -nc --rawfile c "${WORK}/cases/${n}.cmd" --arg cwd "${T}/p" --arg codex "${codex}" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd} + (if $codex != "" then {turn_id:"t1",model:"m"} else {} end)' |
    ( cd "${ROOT_DIR}" && CENSUS_MODE="${mode}" CENSUS_K="${k}" CENSUS_STATE="${T}/st" \
        PATH="${bin}:${PATH}" HOME="${T}/h" SAFEDEPS_HOME="${T}/h/safe" TMPDIR="${T}" \
        scripts/safedeps-hook-entry.sh pre 2>"${T}/stderr" )) || rc=$?
  decision="pass" class="-" updated="-"
  if [[ -n "${out}" ]]; then
    decision=$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${out}" 2>/dev/null || printf 'badjson')
    reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<< "${out}" 2>/dev/null || printf '')
    updated=$(jq -r '.hookSpecificOutput.updatedInput.command // "-"' <<< "${out}" 2>/dev/null || printf '-')
    if [[ "${decision}" == "deny" ]]; then
      if [[ "${reason}" == *UNDECIDED* ]]; then class="undecided"; else class="finding"; fi
    fi
  fi
  # The pending record is compared on what the guard read from the command:
  # the directory, whether a trace was wanted, and why the trace cannot answer
  # for every npm install. The last one was left out until a failed sed could
  # change it unseen: a sed that cannot read an inert head between two npm
  # installs turns the shared trace into an UNGATED one, and a run that changed
  # only that compared as the same.
  pending="-"
  for f in "${T}/h/safe/pending"/*.json; do
    [[ -f "${f}" ]] || continue
    pending=$(jq -r '[.project_dir, (.npm_trace | type), (.npm_unattributable // "")] | join(" ; ")' "${f}" 2>/dev/null \
      || printf 'unreadable')
  done
  # Every counter is a tally file with one line per event (see the shim).
  tally_count() {
    local n=0 line
    [[ -f "$1" ]] || { printf '0'; return 0; }
    while IFS= read -r line; do n=$(( n + 1 )); done < "$1"
    printf '%s' "${n}"
  }
  reads=$(tally_count "${T}/st/reads")
  after=$(tally_count "${T}/st/after-gate")
  failed=$(tally_count "${T}/st/failed")
  unmarked=$(tally_count "${T}/st/unmarked")
  unlisted=$(tally_count "${T}/st/unlisted")
  grep_calls=$(tally_count "${T}/st/grep-calls")
  sed_calls=$(tally_count "${T}/st/sed-calls")
  [[ ! -s "${T}/st/strays" ]] || cp "${T}/st/strays" "${WORK}/strays/${n}.${mode}.${k}"
  # Paths under the run's own temp root differ every run; compare them as T.
  # The guard resolves the project directory, so the root appears in its
  # physical spelling too (macOS: /var is /private/var).
  T_physical=$(cd "${T}" && pwd -P)
  updated="${updated//${T_physical}/T}"
  updated="${updated//${T}/T}"
  pending="${pending//${T_physical}/T}"
  pending="${pending//${T}/T}"
  updated="${updated//$'\n'/\\n}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${n}" "${mode}" "${k}" "${rc}" "${decision}" "${class}" "${updated}" "${pending}" "${reads}" "${after}" "${failed}" \
    "${unmarked}" "${unlisted}" "${grep_calls}" "${sed_calls}" \
    > "${WORK}/results/${n}.${mode}.${k}"
  rm -rf "${T}"
  exit 0
fi

# --- setup ----------------------------------------------------------------------
QUICK=false
# Every run is a guard judging one payload, CPU-bound and independent of the
# others, so the runs scale with CPUs. A fixed 4 left most of a larger machine
# idle; one run per CPU took a shared 16-CPU Mac already at load 100 past 300.
# So the default is half the CPUs, rounded up, and SAFEDEPS_TEST_JOBS (which
# scripts/test/run-all.sh sets for the whole suite) moves it. The cap is the
# largest machine the default was measured on (16 CPUs).
cpus=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf '4')
[[ "${cpus}" =~ ^[1-9][0-9]*$ ]] || cpus=4
JOBS=$(( (cpus + 1) / 2 ))
(( JOBS <= 16 )) || JOBS=16
if [[ -n "${SAFEDEPS_TEST_JOBS:-}" ]]; then
  [[ "${SAFEDEPS_TEST_JOBS}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'census: SAFEDEPS_TEST_JOBS must be a whole number of at least 1 (got %s)\n' "${SAFEDEPS_TEST_JOBS:0:40}" >&2
    exit 2
  }
  JOBS="${SAFEDEPS_TEST_JOBS}"
fi
VARIANTS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true; shift ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --variants) VARIANTS="$2"; shift 2 ;;
    *) printf 'usage: %s [--quick] [--jobs N] [--variants "claude codex padded"]\n' "$0" >&2; exit 2 ;;
  esac
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-census.XXXXXX")
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/cases" "${WORK}/results" "${WORK}/strays"

real_awk=$(command -v awk)
# The shims run as this bash, named by path: they run once per reading of every
# run, and `/usr/bin/env bash` cost one more exec each time.
shim_bash=$(command -v bash)
# The shim counts the guard's readings and fails the chosen ones. Readings can
# run concurrently inside one guard run (a process substitution feeds a loop
# that reads too), so the counters are tally files: one line appended per
# event. A short line appended to a file opened O_APPEND is one write, so
# concurrent shims neither lose nor split one, and nothing is locked. A
# reading's ordinal is the line its own token landed on.
#
# The counters used to be numbers under a mkdir lock, taken in a busy loop with
# no way to tell a dead holder from a slow one. A shim killed between the mkdir
# and the rmdir (the self-budget deadline kills the judgment's whole tree)
# left every later shim of that run spinning at full CPU forever: orphans in
# that state ran for over two hours on a shared Mac and fed a load-300 incident.
cat > "${WORK}/bin/awk" <<SHIM
#!${shim_bash}
real='${real_awk}'
state="\${CENSUS_STATE:-}"
[[ -n "\${state}" ]] || exec "\${real}" "\$@"
tally() { printf '%s\n' "\$2" >> "\${state}/\$1"; }
[[ "\${CENSUS_MODE:-none}" == "awk-all" ]] && { tally failed x; exit 127; }
kind=""
case "\$*" in
  *"safedeps:command_scan_text"*) kind=scan ;;
  *"safedeps:join_line_continuations"*) kind=join ;;
  *"safedeps:install_managers_blanked"*) kind=blank ;;
  *"safedeps:install_match_spans"*) kind=spans ;;
  *"safedeps:strip_heredoc_bodies"*) kind=strip ;;
  *"safedeps:command_reads"*) kind=reads ;;
  *"safedeps:inert_rewrite_in_place"*) kind=inert ;;
  *"safedeps:inert_offsets"*) kind=offsets ;;
  *"safedeps:inert_payload_spans"*) kind=payspans ;;
  *"safedeps:normalize_install_text"*) kind=norm ;;
  *"safedeps:extract_command_substitution_payloads"*) kind=subst ;;
  *"safedeps:command_statements"*) kind=stmts ;;
  *"safedeps:guard_npmrc_value"*) kind=npmrc ;;
  *"safedeps:extract_pieces"*) kind=pieces ;;
  *"safedeps:payload_pieces"*) kind=payload ;;
  *"safedeps:read_payload_words"*) kind=paywords ;;
esac
if [[ -z "\${kind}" ]]; then
  # A call the census cannot name, counted so that it cannot hide: see
  # "unmarked" and "unlisted" in the header.
  case "\$*" in
    *"safedeps:"*) tally unlisted x ;;
    *) tally unmarked x ;;
  esac
  printf '%s\n' "\$*" | tr '\n' ' ' | cut -c1-160 >> "\${state}/strays"
  exec "\${real}" "\$@"
fi
token="\$\$.\${RANDOM}\${RANDOM}"
tally reads "\${token}"
n=0
while IFS= read -r line; do
  n=\$(( n + 1 ))
  [[ "\${line}" != "\${token}" ]] || break
done < "\${state}/reads"
[[ -z "\${SAFEDEPS_GATE_PASSED:-}" ]] || tally after-gate x
fail_it() { tally failed x; exit 2; }
case "\${CENSUS_MODE:-none}" in
  k)       [[ "\${n}" == "\${CENSUS_K}" ]] && fail_it ;;
  from-k)  (( n >= CENSUS_K )) && fail_it ;;
  "\${kind}-all") fail_it ;;
esac
exec "\${real}" "\$@"
SHIM
chmod +x "${WORK}/bin/awk"

# grep and sed sit on the judgment path too, and carry no marker, so their shim
# counts calls rather than readings: the count mode tallies every call, the
# K-th mode fails the K-th call alone, and the all mode fails every call. The
# ordinal is taken the way the awk shim takes it, from a tally file of tokens.
# A call is counted only in the count and K-th modes; the awk-reading K runs
# are numbered by awk calls alone.
#
# sed-all was the only sed mode for a release, and it could not see one site:
# the first judgment sed a command reaches (normalize_install_text) marks its
# failure, and that mark covers every later sed, so a later site whose own mark
# was deleted still read as UNDECIDED (raised in review of v2.18.0). Failing
# one call at a time lets each site answer for itself. Measured on the sed that
# reads an inert head between two npm installs: with its mark deleted, the K-th
# sed run of the two-installs row is weakened (the pending attribution changes
# and nothing is said), where the sed-all run of the same row is UNDECIDED.
#
# Each shim lives in a directory of its own beside the awk shim, and a run puts
# that directory on PATH only in a mode that needs it; the count mode gets both.
# In any other mode the shim would only exec the real tool, at the price of a
# bash start on every grep and sed the guard runs.
mkdir -p "${WORK}/bin-count"
ln -s "${WORK}/bin/awk" "${WORK}/bin-count/awk"
for tool in grep sed; do
  real_tool=$(command -v "${tool}")
  mkdir -p "${WORK}/bin-${tool}"
  ln -s "${WORK}/bin/awk" "${WORK}/bin-${tool}/awk"
  cat > "${WORK}/bin-${tool}/${tool}" <<SHIM
#!${shim_bash}
state="\${CENSUS_STATE:-}"
[[ -n "\${state}" ]] || exec '${real_tool}' "\$@"
# Failures are counted like the awk shim's, so the idle-mode check sees them.
case "\${CENSUS_MODE:-none}" in
  ${tool}-all) printf 'x\n' >> "\${state}/failed"; exit 2 ;;
  ${tool}-k|count)
    token="\$\$.\${RANDOM}\${RANDOM}"
    printf '%s\n' "\${token}" >> "\${state}/${tool}-calls"
    if [[ "\${CENSUS_MODE}" == "${tool}-k" ]]; then
      n=0
      while IFS= read -r line; do
        n=\$(( n + 1 ))
        [[ "\${line}" != "\${token}" ]] || break
      done < "\${state}/${tool}-calls"
      [[ "\${n}" != "\${CENSUS_K}" ]] || { printf 'x\n' >> "\${state}/failed"; exit 2; }
    fi
    ;;
esac
exec '${real_tool}' "\$@"
SHIM
  chmod +x "${WORK}/bin-${tool}/${tool}"
  ln -s "${WORK}/bin-${tool}/${tool}" "${WORK}/bin-count/${tool}"
done

# --- the approved ledger -------------------------------------------------------
# Written once and copied into each approved run. Built with the ledger's own
# writer, so it is whatever the guard reads.
mkdir -p "${WORK}/approved-home"
while IFS=$'\t' read -r eco pkg ver; do
  SAFEDEPS_HOME="${WORK}/approved-home" "${ROOT_DIR}/lib/ledger/ledger.sh" approve "${eco}" "${pkg}" "${ver}" "${ver}" census >/dev/null \
    || { printf 'census: could not approve %s %s %s\n' "${eco}" "${pkg}" "${ver}" >&2; exit 2; }
done < <(jq -r '.approvals[] | @tsv' "${CORPUS}")

# --- cases ----------------------------------------------------------------------
case_count=0
add_case() {
  local command="$1" variant="$2"
  case_count=$(( case_count + 1 ))
  if [[ "${variant}" == "padded" ]]; then
    # A leading no-op statement of quoted filler: it names nothing and changes
    # no reading of what follows, but it takes the command past the 1KB
    # threshold, so the self-budget child judges it instead of the parent.
    command=": '$(printf 'x%.0s' $(seq 1 1100))'; ${command}"
  fi
  printf '%s' "${command}" > "${WORK}/cases/${case_count}.cmd"
  printf '%s' "${variant}" > "${WORK}/cases/${case_count}.variant"
}
quick_variant_rows=$(jq -r '.quick.variants[]? // empty' "${CORPUS}")
variants_for() {
  local index="$1" command="$2" row
  if [[ -n "${VARIANTS}" ]]; then
    printf '%s' "${VARIANTS}"
    return
  fi
  if [[ "${QUICK}" == "true" ]]; then
    while IFS= read -r row; do
      [[ -n "${row}" && "${row}" == "${command}" ]] && { printf 'claude codex padded approved'; return; }
    done <<< "${quick_variant_rows}"
    printf 'claude'
  elif [[ $(( index % 5 )) -eq 0 ]]; then
    printf 'claude codex padded approved'
  else
    printf 'claude approved'
  fi
}
index=0
while IFS= read -r -d '' command; do
  index=$(( index + 1 ))
  for variant in $(variants_for "${index}" "${command}"); do
    add_case "${command}" "${variant}"
  done
done < <(jq -j --arg quick "${QUICK}" '
  (if $quick == "true" then .quick else . end) as $b
  | ($b.forms[] as $f | $b.wrappers[] | sub("\\{\\}"; $f) + "\u0000"),
    ($b.extras[], $b.controls[] | . + "\u0000")' "${CORPUS}")

printf 'safedeps scan-failure census\n'
printf '  cases %d (%s), jobs %d, %s\n' "${case_count}" "$([[ "${QUICK}" == "true" ]] && printf quick || printf full)" "${JOBS}" "$(uptime | sed 's/.*load/load/')"

# --- clean runs -----------------------------------------------------------------
seq 1 "${case_count}" | xargs -P "${JOBS}" -I{} bash "${SELF}" --run "${WORK}" {} none 0

# --- counting runs --------------------------------------------------------------
# A second clean run with the grep and sed shims counting. It is kept apart
# from the clean run so the baseline every failing run is compared with pays
# for no shim but awk's.
seq 1 "${case_count}" | xargs -P "${JOBS}" -I{} bash "${SELF}" --run "${WORK}" {} count 0

# --- failing runs ---------------------------------------------------------------
: > "${WORK}/jobs"
for n in $(seq 1 "${case_count}"); do
  reads=$(cut -f9 "${WORK}/results/${n}.none.0")
  for k in $(seq 1 "${reads}"); do
    printf '%s k %s\n' "${n}" "${k}" >> "${WORK}/jobs"
    [[ "${QUICK}" == "true" ]] || printf '%s from-k %s\n' "${n}" "${k}" >> "${WORK}/jobs"
  done
  if [[ "${QUICK}" != "true" ]]; then
    for k in $(seq 1 "$(cut -f14 "${WORK}/results/${n}.count.0")"); do
      printf '%s grep-k %s\n' "${n}" "${k}" >> "${WORK}/jobs"
    done
  fi
  for k in $(seq 1 "$(cut -f15 "${WORK}/results/${n}.count.0")"); do
    printf '%s sed-k %s\n' "${n}" "${k}" >> "${WORK}/jobs"
  done
  for mode in scan-all join-all strip-all reads-all inert-all offsets-all norm-all subst-all blank-all spans-all stmts-all npmrc-all pieces-all payload-all paywords-all payspans-all awk-all grep-all sed-all; do
    printf '%s %s 0\n' "${n}" "${mode}" >> "${WORK}/jobs"
  done
done
# The K-th runs by tool, so the price of each mode can be read off a log.
printf '  failing runs %d (K-th awk %d, grep %d, sed %d)\n' "$(wc -l < "${WORK}/jobs" | tr -d ' ')" \
  "$(grep -c ' k ' "${WORK}/jobs" || true)" "$(grep -c ' grep-k ' "${WORK}/jobs" || true)" "$(grep -c ' sed-k ' "${WORK}/jobs" || true)"
xargs -P "${JOBS}" -L 1 bash "${SELF}" --run "${WORK}" < "${WORK}/jobs"

# --- verdict --------------------------------------------------------------------
cat "${WORK}/results"/* | awk -F'\t' -v cases="${WORK}/cases" -v strays="${WORK}/strays" '
  $2 == "none" { base[$1] = $5 "\t" $6 "\t" $7 "\t" $8 }
  { row[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      split(row[i], f, "\t")
      n = f[1]; mode = f[2]; k = f[3]; rc = f[4]; dec = f[5]; cls = f[6]
      tuple = f[5] "\t" f[6] "\t" f[7] "\t" f[8]
      if (f[10] + 0 > 0) { count["after-gate"]++; bad[++nb] = "after-gate\t" row[i] }
      if (dec == "deny" && f[8] != "-") { count["pending-on-deny"]++; bad[++nb] = "pending-on-deny\t" row[i] }
      if (mode == "none") {
        count["clean"]++
        if (f[12] + f[13] > 0) {
          sf = strays "/" n ".none.0"; first = ""
          if ((getline first < sf) > 0) close(sf)
          if (f[12] + 0 > 0) { count["unmarked"]++; bad[++nb] = "unmarked\tcase " n ": " f[12] " awk call(s) with no marker, first: " first }
          if (f[13] + 0 > 0) { count["unlisted"]++; bad[++nb] = "unlisted\tcase " n ": " f[13] " awk call(s) with a marker the shim has no kind for, first: " first }
        }
        continue
      }
      # The counting run only numbers the grep and sed calls.
      if (mode == "count") continue
      hits[mode] += f[11]
      split(base[n], b, "\t")
      if (rc != 0) verdict = "error"
      else if (tuple == base[n]) verdict = "same"
      else if (f[11] + 0 == 0) verdict = "unstable"
      else if (dec == "deny" && cls == "undecided") verdict = "undecided"
      else if (dec == "deny") verdict = "mislabeled"
      else verdict = "weakened"
      count[verdict]++
      if (verdict == "error" || verdict == "mislabeled" || verdict == "weakened" || verdict == "unstable") {
        getline cmd < (cases "/" n ".cmd"); close(cases "/" n ".cmd")
        bad[++nb] = verdict "\t" row[i] "\tclean=" base[n] "\tcmd=" cmd
      }
    }
    # A failure mode that failed nothing, in any run, contributed only "same"
    # rows: its zero says nothing. That is how a mode keyed on a marker the
    # guard did not carry went unnoticed (caught in review).
    for (m in hits) if (hits[m] == 0) { count["idle-mode"]++; bad[++nb] = "idle-mode\t" m " failed no call in any run" }
    split("clean same undecided weakened mislabeled error after-gate pending-on-deny idle-mode unmarked unlisted unstable", order, " ")
    for (j = 1; j <= 12; j++) printf "  %-16s %d\n", order[j], count[order[j]] + 0
    for (j = 1; j <= nb; j++) print "  " bad[j]
    fail = count["weakened"] + count["mislabeled"] + count["error"] + count["after-gate"] + count["pending-on-deny"] + count["idle-mode"] + count["unmarked"] + count["unlisted"] + count["unstable"]
    exit (fail > 0 ? 1 : 0)
  }
'
