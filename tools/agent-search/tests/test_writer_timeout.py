"""Affected pipe timeout path: preserve one response and original keys for reconciliation."""
import asyncio
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("companion", Path(__file__).resolve().parents[1] / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


async def exercise():
    with tempfile.TemporaryDirectory() as temp:
        helper = Path(temp) / "writer"
        helper.write_text(f"#!{Path(sys.executable).resolve()}\n" + '''import json,sys,time
from uuid import uuid4
print(json.dumps({"status":"ready","session_id":str(uuid4()),"expires_at":time.time()+30}),flush=True)
seen=set()
for line in sys.stdin:
 c=json.loads(line); i=c["request_id"]
 if c["action"]=="write":
  assert i not in seen
  seen.add(i); time.sleep(0.15)
  result={"status":"pending","request_id":i}
 else:
  assert i in seen
  result={"status":"saved","request_id":i,"clip_id":i}
 print(json.dumps(result),flush=True)
''')
        helper.chmod(0o700)
        server.writer = helper
        server.COMMAND_WAIT_SECONDS = 0.04
        await server.connect_writer()
        result = await server.save_clip("Slow acknowledgement synthetic note")
        assert result["status"] == "unknown"
        assert server.writer_process is not None and server.submitted
        await asyncio.sleep(0.2)
        from uuid import UUID
        checked = await server.check_save(UUID(result["request_id"]))
        assert checked["status"] == "saved"
        assert server.get_clip(UUID(result["request_id"]))["text"] == "Slow acknowledgement synthetic note"
        await server.disconnect()
        assert not server.written and not server.submitted and server.writer_response_pending is None
    print("PASS pipe timeout: original helper/response retained, late ACK drained, same-ID read-only reconciliation, cleanup")


asyncio.run(exercise())
