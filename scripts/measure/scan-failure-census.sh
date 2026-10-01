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
# failing, and with every awk, every grep or every sed failing. Each run is compared with the clean one
# on (decision, finding-or-UNDECIDED, updatedInput, pending project_dir).
#
#   same        identical to the clean run
#   undecided   denied as UNDECIDED -- the gate did its job
#   weakened    anything that lets more through: a deny became allow/pass, the
#               inert rewrite was lost or moved, pending state points elsewhere
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
# awk program (`safedeps:<function>`), and the shim reads that marker.
#
# Usage:
#   scripts/measure/scan-failure-census.sh [--quick] [--jobs N] [--variants "claude codex padded"]
#
#   --quick      the subset npm test runs (the corpus's "quick" block)
#   --jobs N     parallel runs (default 4)
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
# test pays for one failing run per reading rather than two.
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
  variant=$(cat "${WORK}/cases/${n}.variant")
  [[ "${variant}" != "approved" ]] || cp -R "${WORK}/approved-home" "${T}/h/safe"
  codex=""
  [[ "${variant}" == "codex" ]] && codex=1
  rc=0
  out=$(jq -nc --rawfile c "${WORK}/cases/${n}.cmd" --arg cwd "${T}/p" --arg codex "${codex}" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd} + (if $codex != "" then {turn_id:"t1",model:"m"} else {} end)' |
    ( cd "${ROOT_DIR}" && CENSUS_MODE="${mode}" CENSUS_K="${k}" CENSUS_STATE="${T}/st" \
        PATH="${WORK}/bin:${PATH}" HOME="${T}/h" SAFEDEPS_HOME="${T}/h/safe" TMPDIR="${T}" \
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
  pending="-"
  for f in "${T}/h/safe/pending"/*.json; do
    [[ -f "${f}" ]] || continue
    pending=$(jq -r '.project_dir' "${f}" 2>/dev/null || printf 'unreadable')
  done
  reads=$(cat "${T}/st/reads" 2>/dev/null || printf '0')
  after=$(cat "${T}/st/after-gate" 2>/dev/null || printf '0')
  failed=$(cat "${T}/st/failed" 2>/dev/null || printf '0')
  unmarked=$(cat "${T}/st/unmarked" 2>/dev/null || printf '0')
  unlisted=$(cat "${T}/st/unlisted" 2>/dev/null || printf '0')
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
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${n}" "${mode}" "${k}" "${rc}" "${decision}" "${class}" "${updated}" "${pending}" "${reads}" "${after}" "${failed}" \
    "${unmarked}" "${unlisted}" \
    > "${WORK}/results/${n}.${mode}.${k}"
  rm -rf "${T}"
  exit 0
fi

# --- setup ----------------------------------------------------------------------
QUICK=false
JOBS=4
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
# The shim counts the guard's readings and fails the chosen ones. Counting is
# under a mkdir lock: readings can run concurrently inside one guard run (a
# process substitution feeds a loop that reads too).
cat > "${WORK}/bin/awk" <<SHIM
#!/usr/bin/env bash
real='${real_awk}'
state="\${CENSUS_STATE:-}"
[[ -n "\${state}" ]] || exec "\${real}" "\$@"
bump() {
  local f="\${state}/\$1" n
  while ! mkdir "\${state}/lock" 2>/dev/null; do :; done
  n=\$(( \$(cat "\${f}" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "\${n}" > "\${f}"
  rmdir "\${state}/lock"
  printf '%s' "\${n}"
}
[[ "\${CENSUS_MODE:-none}" == "awk-all" ]] && { bump failed >/dev/null; exit 127; }
kind=""
case "\$*" in
  *"safedeps:command_scan_text"*) kind=scan ;;
  *"safedeps:join_line_continuations"*) kind=join ;;
  *"safedeps:install_managers_blanked"*) kind=blank ;;
  *"safedeps:install_match_spans"*) kind=spans ;;
  *"safedeps:extract_flagged_specs"*) kind=flag ;;
  *"safedeps:operand_specs_ecosystem"*) kind=eco ;;
  *"safedeps:strip_heredoc_bodies"*) kind=strip ;;
  *"safedeps:command_reads"*) kind=reads ;;
  *"safedeps:inert_rewrite_in_place"*) kind=inert ;;
  *"safedeps:inert_offsets"*) kind=offsets ;;
  *"safedeps:inert_payload_spans"*) kind=payspans ;;
  *"safedeps:normalize_install_text"*) kind=norm ;;
  *"safedeps:extract_command_substitution_payloads"*) kind=subst ;;
esac
if [[ -z "\${kind}" ]]; then
  # A call the census cannot name, counted so that it cannot hide: see
  # "unmarked" and "unlisted" in the header.
  case "\$*" in
    *"safedeps:"*) bump unlisted >/dev/null ;;
    *) bump unmarked >/dev/null ;;
  esac
  printf '%s\n' "\$*" | tr '\n' ' ' | cut -c1-160 >> "\${state}/strays"
  exec "\${real}" "\$@"
fi
n=\$(bump reads)
[[ -z "\${SAFEDEPS_GATE_PASSED:-}" ]] || bump after-gate >/dev/null
fail_it() { bump failed >/dev/null; exit 2; }
case "\${CENSUS_MODE:-none}" in
  k)       [[ "\${n}" == "\${CENSUS_K}" ]] && fail_it ;;
  from-k)  (( n >= CENSUS_K )) && fail_it ;;
  "\${kind}-all") fail_it ;;
esac
exec "\${real}" "\$@"
SHIM
chmod +x "${WORK}/bin/awk"

# grep and sed sit on the judgment path too. These fail every call in their
# mode and pass everything through otherwise; a reading is not counted by
# them, because the K-th-reading runs are about awk.
for tool in grep sed; do
  real_tool=$(command -v "${tool}")
  cat > "${WORK}/bin/${tool}" <<SHIM
#!/usr/bin/env bash
if [[ -n "\${CENSUS_STATE:-}" && "\${CENSUS_MODE:-none}" == "${tool}-all" ]]; then
  # Counted like the awk shim's failures, so the idle-mode check sees them.
  while ! mkdir "\${CENSUS_STATE}/lock" 2>/dev/null; do :; done
  printf '%s' "\$(( \$(cat "\${CENSUS_STATE}/failed" 2>/dev/null || echo 0) + 1 ))" > "\${CENSUS_STATE}/failed"
  rmdir "\${CENSUS_STATE}/lock"
  exit 2
fi
exec '${real_tool}' "\$@"
SHIM
  chmod +x "${WORK}/bin/${tool}"
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

# --- failing runs ---------------------------------------------------------------
: > "${WORK}/jobs"
for n in $(seq 1 "${case_count}"); do
  reads=$(cut -f9 "${WORK}/results/${n}.none.0")
  for k in $(seq 1 "${reads}"); do
    printf '%s k %s\n' "${n}" "${k}" >> "${WORK}/jobs"
    [[ "${QUICK}" == "true" ]] || printf '%s from-k %s\n' "${n}" "${k}" >> "${WORK}/jobs"
  done
  for mode in scan-all join-all strip-all reads-all inert-all offsets-all payspans-all norm-all subst-all blank-all spans-all flag-all eco-all awk-all grep-all sed-all; do
    printf '%s %s 0\n' "${n}" "${mode}" >> "${WORK}/jobs"
  done
done
printf '  failing runs %d\n' "$(wc -l < "${WORK}/jobs" | tr -d ' ')"
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
