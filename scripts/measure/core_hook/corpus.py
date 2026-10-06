"""Case input validation; this module does not judge hook output."""
import json
import re
from .observe import fail as die

def load_cases(paths, engage_bytes):
    cases = []
    seen = {}
    for p in paths:
        try:
            doc = json.load(open(p, encoding="utf-8"))
        except (OSError, ValueError) as e:
            die("cannot read cases from %s: %s" % (p, e))
        defaults = doc.get("defaults", {})
        for c in doc.get("cases", []):
            if not c.get("bare"):
                # A case starts from the file's defaults; what it names itself wins.
                c["files"] = dict(defaults.get("files", {}), **c.get("files", {}))
            if isinstance(c.get("npm"), str):
                c["npm"] = doc.get("npm", {}).get(c["npm"]) or die("%s: no stand-in npm named %s" % (p, c["npm"]))
            cid = c.get("id")
            if not cid or not re.match(r"^[a-z0-9][a-z0-9-]*$", cid):
                die("%s: a case needs an id of lower-case letters, digits and dashes (%r)" % (p, cid))
            if cid in seen:
                die("case id %s is in both %s and %s" % (cid, seen[cid], p))
            seen[cid] = p
            check_case(c, engage_bytes)
            cases.append(c)
    return cases


def check_case(c, engage_bytes):
    cid = c["id"]
    steps = c.get("steps")
    if not steps:
        die("case %s has no steps" % cid)
    has_post = False
    longest = 0
    for k, s in enumerate(steps):
        if "hook" in s:
            if s["hook"] not in ("pre", "post"):
                die("case %s step %d: hook is pre or post" % (cid, k))
            if sum(x in s for x in ("command", "payload", "payload_raw")) != 1 and "command_from_step" not in s:
                die("case %s step %d: a hook step has command, payload or payload_raw, one of them" % (cid, k))
            if s.get("engine", "claude") not in ("claude", "codex"):
                die("case %s step %d: engine is claude or codex" % (cid, k))
            has_post = has_post or s["hook"] == "post"
            payload = s.get("payload")
            ti = payload.get("tool_input") if isinstance(payload, dict) else None
            cmd = s.get("command", ti.get("command") if isinstance(ti, dict) else None)
            if isinstance(cmd, str):
                longest = max(longest, len(cmd.encode("utf-8")))
            src = s.get("command_from_step")
            if src is not None and not (isinstance(src, int) and 0 <= src < k and "hook" in steps[src]):
                die("case %s step %d: command_from_step names an earlier hook step" % (cid, k))
        elif "effect" not in s:
            die("case %s step %d is neither a hook nor an effect" % (cid, k))
    family = c.get("family", "verdict")
    if family not in ("verdict", "deadline"):
        die("case %s: family is verdict or deadline" % cid)
    providers = c.get("providers", "default")
    if providers not in ("default", "closed", "fixture"):
        die("case %s: providers is default, closed or fixture" % cid)
    if has_post and providers == "default":
        die("case %s has a post step and leaves the advisory providers at their defaults; name closed or fixture" % cid)
    if c.get("seed_cli") and providers == "default":
        die("case %s runs the safedeps CLI in its seed and leaves the providers at their defaults" % cid)
    c["_long"] = longest >= engage_bytes

