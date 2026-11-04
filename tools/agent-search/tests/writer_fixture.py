#!/opt/homebrew/bin/python3.14
"""Synthetic transport only. No app, chooser, database, clipboard, or filesystem writes."""
import json
import sys
import time
from uuid import uuid4

print(json.dumps({"status": "ready", "session_id": str(uuid4()), "expires_at": time.time() + 890}), flush=True)
requests = {}
for raw in sys.stdin:
    command = json.loads(raw)
    action, ident = command["action"], command.get("request_id")
    if action == "disconnect":
        break
    if action == "write":
        assert ident not in requests, "synthetic test would reject duplicate write"
        requests[ident] = [command["text"], 0]
        result = {"status": "pending", "request_id": ident}
    else:
        text, count = requests[ident]
        requests[ident][1] += 1
        if text.startswith("reject:"):
            status = "rejected"
        elif text.startswith("unavailable:"):
            status = "unavailable"
        elif text.startswith("lost-ack:") and count < 3:
            status = "pending"
        elif text.startswith("forever:"):
            status = "pending"
        elif text.startswith("mismatch:"):
            status = "saved"
            ident = str(uuid4())
        else:
            status = "saved"
        result = {"status": status, "request_id": ident}
        if status == "saved":
            result["clip_id"] = ident
    print(json.dumps(result), flush=True)
