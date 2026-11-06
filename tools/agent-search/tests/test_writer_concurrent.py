"""Concurrent requests retain separate identities and the 32-request RAM bound."""
import asyncio
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("companion", Path(__file__).resolve().parents[1] / "server.py")
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)

async def exercise():
    s.writer = Path(__file__).with_name("writer_fixture.py")
    await s.connect_writer()
    s.SAVE_WAIT_SECONDS = 0.2
    tasks = [asyncio.create_task(s.save_clip(f"forever: synthetic queued note {i}")) for i in range(32)]
    await asyncio.sleep(0)
    assert len(s.submitted) == 32
    try:
        await s.save_clip("must not create a thirty-third request")
        raise AssertionError("capacity exceeded")
    except ValueError:
        pass
    results = await asyncio.gather(*tasks)
    assert len({r["request_id"] for r in results}) == 32
    assert all(r["status"] == "unknown" for r in results)
    assert len(s.submitted) == 32 and not s.written
    await s.disconnect()
    assert not s.submitted and s.writer_process is None
    print("PASS: 32 concurrent IDs, capacity refusal, unknown outcomes retained, disconnect cleanup")

asyncio.run(exercise())
