"""Source mutations, applied to private copies only."""
import os
import shutil
from .observe import fail as die

MUTATIONS = [
    {"name": "exit-status", "cases": ["pre-npm-install-codex"], "file": "scripts/safedeps-pre-guard.sh", "channel": "status",
     "old": "# Allow the command to proceed — PostToolUse will verify the result\nexit 0\n",
     "new": "# Allow the command to proceed — PostToolUse will verify the result\nexit 3\n"},
    {"name": "stdout-bytes", "cases": ["pre-npm-install", "pre-npm-ci-tree"], "file": "scripts/safedeps-pre-guard.sh", "channel": "stdout",
     "old": """      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:{command:$command}}}'\n    exit 0\n""",
     "new": """      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:{command:($command + " ")}}}'\n    exit 0\n"""},
    {"name": "advisory-to-stderr", "cases": ["pre-npm-install"], "file": "scripts/safedeps-pre-guard.sh", "channel": "stderr",
     "old": """  printf '%s\\t%s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "${GUARD_DIR}/advisory.log" 2>/dev/null || true\n""",
     "new": """  printf '%s\\t%s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >&2 || true\n"""},
    {"name": "advisory-wording", "cases": ["pre-npm-install-no-call-id"], "file": "scripts/safedeps-pre-guard.sh", "channel": "tree:state/advisory.log",
     "old": """  CALL_ID_WHY="this hook's input names no tool_use_id"\n""",
     "new": """  CALL_ID_WHY="this hook's input names no tool use id"\n"""},
    {"name": "time-format", "cases": ["pre-npm-install"], "file": "scripts/safedeps-pre-guard.sh", "channel": "tree:state/advisory.log",
     "old": """  printf '%s\\t%s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "${GUARD_DIR}/advisory.log" 2>/dev/null || true\n""",
     "new": """  printf '%s\\t%s\\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$1" >> "${GUARD_DIR}/advisory.log" 2>/dev/null || true\n"""},
    {"name": "record-field", "cases": ["pre-npm-install"], "file": "scripts/safedeps-pre-guard.sh", "channel": "tree:state/snapshots/*_meta.json",
     "old": '  "record": 2,\n', "new": '  "record": 3,\n'},
    {"name": "file-mode", "cases": ["pre-npm-install"], "file": "scripts/safedeps-pre-guard.sh", "channel": "tree:state/advisory.log",
     "old": 'umask 077\nmkdir -p "${GUARD_DIR}" "${SNAPSHOT_DIR}"\n', "new": 'umask 022\nmkdir -p "${GUARD_DIR}" "${SNAPSHOT_DIR}"\n'},
    {"name": "wrong-inode", "cases": ["pre-npm-ci-tree"], "file": "scripts/safedeps-pre-guard.sh", "channel": "violation:pending-inode",
     "old": """    --arg lock "$(guard_file_inode "${PROJECT_DIR}/package-lock.json")" \\\n""",
     "new": """    --arg lock "$(guard_file_inode "${PROJECT_DIR}/package.json")" \\\n"""},
    {"name": "snapshot-named", "cases": ["pre-npm-install"], "file": "scripts/safedeps-pre-guard.sh", "channel": "tree:state/pending/id-*.json",
     "old": """  '{snapshot_id: $sid, project_dir: $pdir, dir_hash: $dhash, project_dir_from: $from,\n""",
     "new": """  '{snapshot_id: ($sid + "-1"), project_dir: $pdir, dir_hash: $dhash, project_dir_from: $from,\n"""},
    {"name": "tmp-left-behind", "cases": ["pre-npm-install"], "file": "scripts/safedeps-pre-guard.sh", "channel": "tree:tmp/safedeps-lex.*",
     "old": """trap 'release_state_lock; rm -f "${SAFEDEPS_SCAN_MARK:-}"; rm -rf "${SAFEDEPS_LEX_CACHE:-}"' EXIT\n""",
     "new": """trap 'release_state_lock; rm -f "${SAFEDEPS_SCAN_MARK:-}"' EXIT\n"""},
    {"name": "post-log-entry", "cases": ["npm-install-no-trace"], "file": "scripts/safedeps-post-verify.sh", "channel": "tree:state/advisory.log",
     "old": """  printf '%s\\t%s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "${GUARD_DIR}/advisory.log" 2>/dev/null || true\n""",
     "new": """  printf '%s\\t%s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1 " >> "${GUARD_DIR}/advisory.log" 2>/dev/null || true\n"""},
    # A seeded value stated wrongly, in the shape of the right one: each is a
    # value a mask would take by its shape alone. They have to be red, so the
    # masks are shown to take only what this run wrote.
    {"name": "seed-iso", "cases": ["post-journal-unfinished"], "file": "lib/gates/rollback-journal.sh", "channel": "stdout",
     "old": """    journal_line="Journal: ${journal_id}, opened ${opened_at}; last recorded stage ${stage}${stage_detail}"\n""",
     "new": """    journal_line="Journal: ${journal_id}, opened ${stage_at:-${opened_at}}; last recorded stage ${stage}${stage_detail}"\n"""},
    {"name": "seed-pid", "cases": ["post-journal-unfinished"], "file": "lib/gates/rollback-journal.sh", "channel": "stdout",
     "old": """  SAFEDEPS_JOURNAL_OWNER_FACT="pid ${pid} is not running"\n""",
     "new": """  SAFEDEPS_JOURNAL_OWNER_FACT="pid ${pid%?}8 is not running"\n"""},
    {"name": "seed-snapshot-id", "cases": ["post-journal-unfinished"], "file": "lib/gates/rollback-journal.sh", "channel": "stdout",
     "old": """    printf 'Rollback snapshot: %s; no confirmed snapshot names it' "${snap}"\n""",
     "new": """    printf 'Rollback snapshot: %s; no confirmed snapshot names it' "${snap%?}3"\n"""},
    # The incident record is the journal entry, moved. The copy changes the
    # seeded epoch's last digit and keeps the entry's inode, mode and other bytes.
    {"name": "seed-epoch", "cases": ["post-journal-unfinished"], "file": "lib/gates/rollback-journal.sh", "channel": "tree:state/rollback-incidents/*",
     "old": """    mv -f "${entry}" "${SAFEDEPS_INCIDENT_DIR}/${journal_id}.json" 2>/dev/null || rm -f "${entry}"\n""",
     "new": """    { sed 's/"at": 1767225600/"at": 1767225601/' "${entry}" > "${entry}.m" && cat "${entry}.m" > "${entry}"; rm -f "${entry}.m"; }; mv -f "${entry}" "${SAFEDEPS_INCIDENT_DIR}/${journal_id}.json" 2>/dev/null || rm -f "${entry}"\n"""},
]


def mutant_tree(ctx, m):
    src = os.path.join(ctx.ref_root, m["file"])
    with open(src, "rb") as f:
        text = f.read()
    old, new = m["old"].encode("utf-8"), m["new"].encode("utf-8")
    if text.count(old) != 1:
        die("control %s: its line is not in %s exactly once (found %d times)" % (m["name"], m["file"], text.count(old)))
    root = os.path.join(ctx.work, "mutant-" + m["name"])
    os.makedirs(root)
    for d in ("scripts", "lib", "bin"):
        shutil.copytree(os.path.join(ctx.ref_root, d), os.path.join(root, d), symlinks=True,
                        ignore=shutil.ignore_patterns("measure", "test", "ci", "native"))
    with open(os.path.join(root, m["file"]), "wb") as f:
        f.write(text.replace(old, new))
    return root

