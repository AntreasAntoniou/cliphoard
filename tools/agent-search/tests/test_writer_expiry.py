"""Affected old-expiry race and monotonic deadline without a user chooser."""
import asyncio
import importlib.util
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("companion", Path(__file__).resolve().parents[1] / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


async def exercise():
    server.writer = Path(__file__).with_name("writer_fixture.py")
    await server.connect_writer()
    old_process, old_generation = server.writer_process, server.generation
    await server.disconnect()
    await server.connect_writer()
    new_process = server.writer_process
    await server.expire_writer(old_process, old_generation)
    assert server.writer_process is new_process and server.writer_live()
    result = await server.save_clip("Current session synthetic note")
    assert result["status"] == "saved"
    server.writer_deadline = time.monotonic() - 1
    assert not server.writer_live()
    try:
        server.shared()
        raise AssertionError("expired cache exposed")
    except ValueError:
        pass
    await server.expire_writer(new_process, server.generation)
    assert not server.written and not server.submitted
    assert server.writer_process is None and new_process.returncode is not None
    print("PASS expiry: queued old-session expiration cannot close new writer; monotonic deadline denies cached notes and clears helper/keys")


asyncio.run(exercise())
