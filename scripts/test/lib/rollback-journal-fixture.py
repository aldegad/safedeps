#!/usr/bin/env python3
"""Write one synthetic journal record; the native post hook judges it."""
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

target, journal_id, project, snapshot, reasons, stage, pid = sys.argv[1:]
record = {
    "journal_id": journal_id,
    "project_dir": project,
    "rollback_snapshot": snapshot,
    "reasons": reasons,
    "stage": stage,
    "opened_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "pid": pid,
}
path = Path(target)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(record) + "\n")
