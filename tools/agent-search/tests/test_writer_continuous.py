"""Synthetic helper exercises continuous lifetime, bounded caches, uncertain retention, and exit revocation."""
import asyncio
import importlib.util
import os
from pathlib import Path
from uuid import UUID

spec = importlib.util.spec_from_file_location("companion", Path(__file__).resolve().parents[1] / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

async def exercise():
    os.environ["CLIPHOARD_SYNTHETIC_CONTINUOUS"] = "1"
    server.writer = Path(__file__).with_name("writer_fixture.py")
    connected = await server.connect_writer()
    assert "while Cliphoard runs" in connected and server.writer_deadline is None
    assert server.writer_expiry is None
    first = None
    for index in range(40):
        saved = await server.save_clip(f"Continuous synthetic note {index}")
        assert saved["status"] == "saved"
        first = first or saved["request_id"]
    assert len(server.written) == 32 and len(server.completed) == 32 and not server.submitted
    assert first not in server.shared()
    try:
        await server.check_save(UUID(first))
        raise AssertionError("evicted response was retained")
    except ValueError:
        pass
    last = await server.check_save(UUID(saved["request_id"]))
    assert last == saved
    # Export revocation is separate from Full access and its saved-note cache.
    server.clips = {"fixture": {"id": "fixture", "text": "exported"}}
    server.expire_export()
    assert server.writer_live() and len(server.shared()) == 32
    server.SAVE_WAIT_SECONDS = 0
    unknown = []
    for index in range(32):
        result = await server.save_clip(f"forever: uncertain {index}")
        assert result["status"] == "unknown"
        unknown.append(result["request_id"])
    assert len(server.submitted) == 32 and set(server.submitted) == set(unknown)
    try:
        await server.save_clip("must not allocate a new request")
        raise AssertionError("unresolved capacity exceeded")
    except ValueError:
        pass
    await server.check_save(UUID(unknown[0]))
    assert len(server.submitted) == 32
    old_process, old_epoch = server.writer_process, server.generation
    await server.disconnect()
    assert not server.submitted and not server.written and not server.completed
    await server.connect_writer()
    current = server.writer_process
    await server.expire_writer(old_process, old_epoch)
    assert server.writer_process is current and server.writer_live()
    # Only this synthetic child exits; no actual app or user process is touched.
    result = await server.save_clip("exit: synthetic host/helper termination")
    assert result["status"] == "unknown"
    for _ in range(100):
        if server.writer_process is None:
            break
        await asyncio.sleep(0.01)
    assert server.writer_process is None and not server.written and not server.submitted
    await server.disconnect()
    os.environ.pop("CLIPHOARD_SYNTHETIC_CONTINUOUS")
    print("PASS continuous writer: 40 saves, bounded terminal/text caches, 32 unresolved preserved, read-export separation, stale exit fence, helper exit clears RAM")

asyncio.run(exercise())
