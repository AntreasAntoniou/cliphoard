"""Actual MCP pipes -> native transport/controller -> SQLite -> authenticated reply -> search/get.
Only the chooser, native user approval, and storage Crypto key custody are synthetic.
"""
import asyncio
import json
import os
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

if sys.argv[1:] == ["--fixture-server"]:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    import server
    os.environ["CLIPHOARD_COMPOSED_CONTINUOUS"] = "1"
    server.writer = Path(sys.executable).parent / "cliphoard-composed-writer"
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
        connected = await call("connect_writer", {})
        assert not connected.isError and "while Cliphoard runs" in connected.content[0].text
        note = "Research note about a purple bicycle and multimodal memory."
        saved = value(await call("save_clip", {"text": note}))
        assert saved["status"] == "saved" and saved["clip_id"] == saved["request_id"]
        match = value(await call("search", {"query": "PURPLE bicycle"}))
        assert match["id"] == saved["clip_id"]
        assert value(await call("get_clip", {"clip_id": match["id"]}))["text"] == note
        assert value(await call("check_save", {"request_id": saved["request_id"]}))["status"] == "saved"
        denied = value(await call("save_clip", {"text": "Contact owner@example.com"}))
        assert denied["status"] == "rejected"
        assert (await call("get_clip", {"clip_id": denied["request_id"]})).isError
        await call("disconnect", {})
        assert (await call("get_clip", {"clip_id": saved["clip_id"]})).isError
    print("PASS continuous composed: real MCP + kernel host identity + native Full access without per-note approval after simulated1000seconds + async real SQLite sealed readback + authenticated receipt + search/get + sensitive rejection + disconnect")


asyncio.run(exercise())
