"""Drive the official MCP client over actual pipes; only the chooser is replaced."""
import asyncio
import json
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

if __name__ == "__main__" and sys.argv[1:] == ["--fixture-server"]:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    import server

    server.reader = Path(sys.executable).parent / "cliphoard-agent-fixture"
    server.server.run(transport="stdio")
    sys.exit(0)


async def exercise() -> None:
    params = StdioServerParameters(command=sys.executable, args=[__file__, "--fixture-server"])
    async with stdio_client(params) as (receive, send), ClientSession(receive, send) as client:
        await client.initialize()
        assert {t.name for t in (await client.list_tools()).tools} == {
            "connect", "search", "get_clip", "disconnect"}
        call = client.call_tool
        assert (await call("search", {"query": "bicycle"})).isError
        opened = await call("connect", {})
        assert not opened.isError and "1 shared clip" in opened.content[0].text
        hits = await call("search", {"query": "BICYCLE red"})
        assert not hits.isError and len(hits.content) == 1
        hit = json.loads(hits.content[0].text)
        assert hit["id"].endswith("0001") and len(hit["preview"]) == 160
        get = lambda ident, offset=0: call("get_clip", {"clip_id": ident, "offset": offset})
        first = json.loads((await get(hit["id"])).content[0].text)
        second = json.loads((await get(hit["id"], first["next_offset"])).content[0].text)
        assert first["text"] + second["text"] == "The red bicycle. " + "pedal " * 800
        assert second["next_offset"] is None
        assert (await get("00000000-0000-4000-8000-000000000002")).isError
        assert (await call("search", {"query": "red", "limit": 100})).isError
        await call("disconnect", {})
        assert (await get(hit["id"])).isError
    print("PASS: real MCP handshake, archive filter, search, full retrieval, pagination and revocation")


if __name__ == "__main__":
    asyncio.run(exercise())
