#!/usr/bin/env bash
# safedeps: measure what a kill during the effect gate's ROLLBACK leaves behind.
#
# The pre-guard's failure mode past its budget is one unjudged command. The
# effect gate's is different in kind: the gate rolls the project back, and the
# rollback is a sequence of file restores followed by a node_modules reinstall.
# A kill lands somewhere inside that sequence. This harness drives the real
# hooks end to end in a sandbox, kills the post hook at a given offset, and
# prints the state the project and the log were left in.
#
# Usage:
#   scripts/measure/rollback-kill-state.sh [offset...]
#
# An offset is `control` (no kill), a number of seconds, or `rollback+<delta>`,
# which waits for the rollback's first visible act and kills <delta> seconds
# later — the only form that lands inside the node_modules reinstall reliably.
#
# With no arguments it sweeps a few offsets plus a no-kill control.

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OFFSETS=("$@")
[[ ${#OFFSETS[@]} -eq 0 ]] && OFFSETS=(control 1 2 3 5)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-rollback.XXXXXX")
trap 'rm -rf "${WORK}"' EXIT

BASELINE_DEP='ms'
BASELINE_VER='2.1.3'
# A second dependency the ledger has NOT approved, so the effect gate flags the
# closure and takes the rollback path. Enough transitive packages that the
# node_modules reinstall is a window a kill can land inside.
BAD_DEP="${SAFEDEPS_ROLLBACK_BAD_DEP:-express}"
BAD_VER="${SAFEDEPS_ROLLBACK_BAD_VER:-4.21.2}"

hook_payload() {
  local command="$1" cwd="$2"
  jq -nc --arg c "${command}" --arg d "${cwd}" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d}'
}

run_case() {
  local offset="$1"
  local case_dir="${WORK}/case-${offset}"
  local project="${case_dir}/project"
  local sd_home="${case_dir}/safedeps-home"

  mkdir -p "${project}" "${sd_home}"
  export SAFEDEPS_HOME="${sd_home}"
  export SAFEDEPS_LEDGER_DIR="${sd_home}/approved-specs"
  export SAFEDEPS_CACHE_DIR="${sd_home}/cache"

  # --- baseline: a project whose closure the ledger approves ---
  cat > "${project}/package.json" <<JSON
{ "name": "safedeps-rollback-sandbox", "version": "1.0.0",
  "dependencies": { "${BASELINE_DEP}": "${BASELINE_VER}" } }
JSON
  (cd "${project}" && npm install --ignore-scripts --silent >/dev/null 2>&1)
  "${REPO_DIR}/bin/safedeps" check npm "${BASELINE_DEP}@${BASELINE_VER}" --json >/dev/null 2>&1

  # Drive the real hooks once so the baseline becomes a CONFIRMED snapshot —
  # that is what the rollback restores from.
  local cmd_baseline="npm install ${BASELINE_DEP}@${BASELINE_VER}"
  hook_payload "${cmd_baseline}" "${project}" \
    | bash "${REPO_DIR}/scripts/safedeps-pre-guard.sh" >/dev/null 2>&1
  hook_payload "${cmd_baseline}" "${project}" \
    | bash "${REPO_DIR}/scripts/safedeps-post-verify.sh" >/dev/null 2>&1

  local confirmed_count
  confirmed_count=$(find "${sd_home}" -maxdepth 1 -name 'confirmed_*' | wc -l | tr -d ' ')
  if [[ "${confirmed_count}" -eq 0 ]]; then
    printf '%-13s  SETUP FAILED: no confirmed baseline snapshot\n' "${offset}"
    return
  fi

  # --- the install the gate must roll back ---
  local cmd_bad="npm install ${BAD_DEP}@${BAD_VER}"
  hook_payload "${cmd_bad}" "${project}" \
    | bash "${REPO_DIR}/scripts/safedeps-pre-guard.sh" >/dev/null 2>&1
  (cd "${project}" && npm install --ignore-scripts --silent "${BAD_DEP}@${BAD_VER}" >/dev/null 2>&1)

  local pre_pkg_hash pre_lock_entries
  pre_pkg_hash=$(shasum -a 256 "${project}/package.json" | cut -d' ' -f1)
  pre_lock_entries=$(jq '.packages | length' "${project}/package-lock.json" 2>/dev/null || echo '?')

  # --- run the post hook, killing it at the requested offset ---
  local killed='no'
  if [[ "${offset}" == "control" ]]; then
    local t_start t_end
    t_start=$(python3 -c 'import time; print(time.time())')
    hook_payload "${cmd_bad}" "${project}" \
      | bash "${REPO_DIR}/scripts/safedeps-post-verify.sh" >/dev/null 2>&1
    t_end=$(python3 -c 'import time; print(time.time())')
    CONTROL_SECONDS=$(python3 -c "print('%.2f' % ($t_end - $t_start))")
  else
    hook_payload "${cmd_bad}" "${project}" \
      | bash "${REPO_DIR}/scripts/safedeps-post-verify.sh" >/dev/null 2>&1 &
    local hook_pid=$!
    if [[ "${offset}" == rollback+* ]]; then
      # Wall-clock offsets cannot land reliably inside the reinstall, because
      # the detection phase's duration varies per run. Instead, watch for the
      # rollback's own first visible act (package.json restored) and kill a
      # fixed delta after it — that is deterministically inside
      # restore_node_modules, the step that deletes and rebuilds the tree.
      local delta="${offset#rollback+}"
      local waited=0
      while kill -0 "${hook_pid}" 2>/dev/null; do
        local live_hash
        live_hash=$(shasum -a 256 "${project}/package.json" 2>/dev/null | cut -d' ' -f1)
        [[ "${live_hash}" != "${pre_pkg_hash}" ]] && break
        sleep 0.05
        waited=$((waited + 1))
        (( waited > 2000 )) && break
      done
      sleep "${delta}"
    else
      sleep "${offset}"
    fi
    if kill -0 "${hook_pid}" 2>/dev/null; then
      # SIGKILL: the runtime's hook timeout does not let the hook clean up, and
      # neither does this.
      kill -9 "${hook_pid}" 2>/dev/null
      killed='yes'
    fi
    wait "${hook_pid}" 2>/dev/null
  fi

  # --- what was left ---
  local post_pkg_hash post_lock_entries nm_state deps_in_pkg
  post_pkg_hash=$(shasum -a 256 "${project}/package.json" 2>/dev/null | cut -d' ' -f1)
  post_lock_entries=$(jq '.packages | length' "${project}/package-lock.json" 2>/dev/null || echo 'ABSENT')
  deps_in_pkg=$(jq -r '.dependencies | keys | join("+")' "${project}/package.json" 2>/dev/null || echo 'ABSENT')
  if [[ ! -d "${project}/node_modules" ]]; then
    nm_state='ABSENT'
  else
    nm_state=$(find "${project}/node_modules" -maxdepth 1 -mindepth 1 -not -name '.*' | wc -l | tr -d ' ')
  fi

  # A SIGKILL to the hook does not kill the `npm ci` it spawned; that child is
  # reparented and keeps writing into node_modules. Give it a moment and look
  # again, so the reading distinguishes "tree torn" from "tree repaired by an
  # orphan the gate no longer knows about".
  local nm_settled
  sleep 8
  if [[ ! -d "${project}/node_modules" ]]; then
    nm_settled='ABSENT'
  else
    nm_settled=$(find "${project}/node_modules" -maxdepth 1 -mindepth 1 -not -name '.*' | wc -l | tr -d ' ')
  fi

  local journal_state
  if [[ -d "${sd_home}/rollback-journal" ]] && \
     [[ -n "$(find "${sd_home}/rollback-journal" -maxdepth 1 -name '*.json' 2>/dev/null)" ]]; then
    journal_state='OPEN'
  elif [[ -d "${sd_home}/rollback-incidents" ]] && \
       [[ -n "$(find "${sd_home}/rollback-incidents" -maxdepth 1 -name '*.json' 2>/dev/null)" ]]; then
    journal_state='reported'
  else
    journal_state='-'
  fi

  local reorg_lines advisory_lines lock_left
  reorg_lines=$([[ -f "${sd_home}/reorg.log" ]] && wc -l < "${sd_home}/reorg.log" | tr -d ' ' || echo 0)
  advisory_lines=$([[ -f "${sd_home}/advisory.log" ]] && wc -l < "${sd_home}/advisory.log" | tr -d ' ' || echo 0)
  lock_left=$([[ -d "${sd_home}/state.lock" ]] && echo 'HELD' || echo '-')

  local pkg_state
  if [[ "${post_pkg_hash}" == "${pre_pkg_hash}" ]]; then
    pkg_state='not-restored'
  elif [[ -z "${post_pkg_hash}" ]]; then
    pkg_state='ABSENT'
  else
    pkg_state='restored'
  fi

  printf '%-13s  %-7s  %-13s  %-7s  %-6s %-8s  %-9s  %-9s  %s\n' \
    "${offset}" "${killed}" "${pkg_state}" "${post_lock_entries}" "${nm_state}" "${nm_settled}" \
    "${journal_state}" "${reorg_lines}" "${lock_left}" \
    | sed "s|\$| deps=${deps_in_pkg}|"
}

printf 'sandbox: baseline %s@%s (confirmed) then unapproved %s@%s\n' \
  "${BASELINE_DEP}" "${BASELINE_VER}" "${BAD_DEP}" "${BAD_VER}"
printf 'kill signal: SIGKILL (the runtime hook timeout does not let the hook clean up either)\n\n'
printf '%-13s  %-7s  %-13s  %-7s  %-6s %-8s  %-9s  %-9s  %s\n' \
  'offset' 'killed' 'package.json' 'lock' 'nm@t0' 'nm@t0+8s' 'journal' 'reorg.log' 'state.lock'
CONTROL_SECONDS=""
for offset in "${OFFSETS[@]}"; do
  run_case "${offset}"
done
[[ -n "${CONTROL_SECONDS}" ]] && printf '\ncontrol run (detect + rollback, uninterrupted): %ss\n' "${CONTROL_SECONDS}"

