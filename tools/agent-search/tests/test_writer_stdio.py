"""Official MCP pipes with a synthetic native helper, including uncertain acknowledgement."""
import asyncio
import json
import sys
from pathlib import Path
from uuid import uuid4

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

if sys.argv[1:] == ["--fixture-server"]:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    import server
    server.writer = Path(__file__).with_name("writer_fixture.py")
    server.SAVE_WAIT_SECONDS = 0.55
    server.server.run(transport="stdio")
    sys.exit(0)


def value(result):
    assert not result.isError, result
    return json.loads(result.content[0].text)


async def exercise():
    params = StdioServerParameters(command=sys.executable, args=[__file__, "--fixture-server"])
    async with stdio_client(params) as (receive, send), ClientSession(receive, send) as client:
        await client.initialize()
        call = client.call_tool
        assert (await call("save_clip", {"text": "before connect"})).isError
        assert not (await call("connect_writer", {})).isError
        empty = await call("search", {"query": "bicycle"})
        assert not empty.isError and not empty.content
        assert (await call("save_clip", {"text": "é" * 16385})).isError
        assert (await call("save_clip", {"text": "  \n"})).isError
        assert (await call("save_clip", {"text": "bad\x00text"})).isError
        saved = value(await call("save_clip", {"text": "Synthetic red bicycle note"}))
        assert saved["status"] == "saved" and saved["clip_id"] == saved["request_id"]
        hit = value(await call("search", {"query": "RED bicycle"}))
        assert hit["id"] == saved["clip_id"]
        note = value(await call("get_clip", {"clip_id": hit["id"]}))
        assert note["text"] == "Synthetic red bicycle note"
        assert value(await call("check_save", {"request_id": saved["request_id"]}))["status"] == "saved"
        for prefix in ("reject:", "unavailable:"):
            denied = value(await call("save_clip", {"text": prefix + " private synthetic"}))
            assert denied["status"] == ("rejected" if prefix == "reject:" else "unknown")
            assert (await call("get_clip", {"clip_id": denied["request_id"]})).isError
        unknown = value(await call("save_clip", {"text": "lost-ack: recover me"}))
        assert unknown["status"] == "unknown"
        assert (await call("get_clip", {"clip_id": unknown["request_id"]})).isError
        reconciled = value(await call("check_save", {"request_id": unknown["request_id"]}))
        assert reconciled["status"] == "saved" and reconciled["request_id"] == unknown["request_id"]
        mismatch = value(await call("save_clip", {"text": "mismatch: refuse wrong identity"}))
        assert mismatch["status"] == "unknown"
        assert (await call("get_clip", {"clip_id": mismatch["request_id"]})).isError
        assert (await call("check_save", {"request_id": str(uuid4())})).isError
        flight = asyncio.create_task(call("save_clip", {"text": "forever: pending revocation"}))
        await asyncio.sleep(0.1)
        assert (await call("save_clip", {"text": "parallel request"})).isError
        await call("disconnect", {})
        assert value(await flight)["status"] == "unknown"
        assert (await call("get_clip", {"clip_id": saved["clip_id"]})).isError
        assert (await call("check_save", {"request_id": unknown["request_id"]})).isError
        assert not (await call("connect_writer", {})).isError
        assert (await call("get_clip", {"clip_id": saved["clip_id"]})).isError
        await call("disconnect", {})
    print("PASS MCP writer: connection, byte bounds, approved-only cache, rejection, lost-ACK reconciliation, identity fencing, single flight, disconnect/reconnect")


if __name__ == "__main__":
    asyncio.run(exercise())
