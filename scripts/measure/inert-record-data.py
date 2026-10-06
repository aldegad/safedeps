#!/usr/bin/env python3
# The data set of scripts/measure/inert-record-invariant.sh: npm install text
# that is data, beside an install (an echo, a commit message, a heredoc written
# to a file, a pattern, a comment). Nothing here runs npm. The record is an
# allow-list over the command's bytes, so most of these are recorded: that is
# the rule's cost, reported as noise, never failed.
#
# usage: python3 scripts/measure/inert-record-data.py > scripts/measure/inert-record-data.jsonl
import json
P="npm ci x"; SQ="'npm ci x'"; DQ='"npm ci x"'
rows=[
 ("echo sq", f"echo {SQ}"), ("echo dq", f"echo {DQ}"), ("echo bare", f"echo {P}"),
 ("printf", f"printf '%s\\n' {SQ}"), ("git commit -m sq", f"git commit -q -m {SQ} 2>/dev/null; true"),
 ("git commit -m dq prose", "git commit -q -m \"chore: run npm ci x in CI\" 2>/dev/null; true"),
 ("git commit heredoc msg", f"git commit -q -F - <<'EOF' 2>/dev/null; true\nfix: {P} in docs\nEOF"),
 ("cat > file <<'E'", f"cat > notes.txt <<'E'\nthen {P}\nE"), ("cat > file <<E", f"cat > notes.txt <<E\n{P}\nE"),
 ("cat >> file <<-E", f"cat >> notes.txt <<-E\n\t{P}\n\tE"), ("tee file <<<", f"tee notes.txt <<< {SQ} > /dev/null"),
 ("grep pattern", f"grep -c {SQ} /dev/null; true"), ("comment", f"true # {P}"), ("colon arg", f": {SQ}"),
 ("assignment", f"msg={SQ}; echo \"$msg\" > /dev/null"), ("jq --arg", f"jq -n --arg m {SQ} '$m' > /dev/null"),
 ("printf >> file", f"printf '%s\\n' {SQ} >> notes.txt"), ("data heredoc | grep", f"cat <<E | grep -c npm\n{P}\nE"),
 ("echo | grep", f"echo {SQ} | grep -c npm"), ("sed script", f"sed -n 's/{P}/x/p' /dev/null"),
 ("awk print", f"awk 'BEGIN {{ print \"{P}\" }}' > /dev/null"), ("readme heredoc md", f"cat > R.md <<'E'\n## Install\n\n```\n{P}\n```\nE"),
 ("json with script", "printf '%s\\n' '{\"scripts\":{\"ci\":\"npm ci x\"}}' > s.json"),
 ("echo mention only", "echo 'npm is slow'"), ("echo npm run", "echo 'npm run build'"),
]
for i,(t,c) in enumerate(rows,1):
    print(json.dumps({"id":f"d{i:03d}","tag":"D|"+t,"cmd":"npm i y && "+c},ensure_ascii=False))
