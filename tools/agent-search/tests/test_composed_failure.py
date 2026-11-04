"""Affected composed negative path: real deferred SQLite COMMIT failure never becomes a saved ACK/cache."""
import asyncio
import json
import sys
from pathlib import Path
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def exercise():
    fixture = Path(__file__).with_name("test_composed_stdio.py")
    params = StdioServerParameters(command=sys.executable, args=[str(fixture), "--fixture-server"])
    async with stdio_client(params) as (receive, send), ClientSession(receive, send) as client:
        await client.initialize()
        call = client.call_tool
        assert not (await call("connect_writer", {})).isError
        failed = await call("save_clip", {"text": "commit-failure: this synthetic note must remain absent"})
        assert not failed.isError
        result = json.loads(failed.content[0].text)
        assert result["status"] == "unknown"
        assert (await call("get_clip", {"clip_id": result["request_id"]})).isError
        search = await call("search", {"query": "synthetic"})
        assert not search.isError and not search.content
        checked = await call("check_save", {"request_id": result["request_id"]})
        assert json.loads(checked.content[0].text)["status"] == "unknown"
        await call("disconnect", {})
    print("PASS composed failure: real deferred COMMIT rejection rolls back SQLite, authenticated unavailable mapped to unknown, no MCP saved text/get/search publication")


asyncio.run(exercise())
