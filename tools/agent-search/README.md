# Search Cliphoard from an agent

This macOS companion works with the encrypted history export in Cliphoard Pro, including TestFlight 1.0.3 (18). It exposes four MCP tools over stdio. The agent can search and retrieve text you explicitly share. Search matches all query words without regard to case. Plain text, links and color strings are supported.

1. Inspect a clip in Cliphoard and add the custom tag `agent-share` under **Tags → Yours**. In Settings, use **Move to another Mac → Export** and save the encrypted archive.
2. Run `tools/agent-search/install.sh` from a source checkout on the Mac. It requires the Swift compiler and Python 3.13 or newer. If needed set `CLIPHOARD_PYTHON` to the absolute interpreter path. The installer builds the archive reader from Cliphoard's own sources and installs the official Python MCP SDK in a private virtual environment.
3. Register it with an MCP client. For Codex, use the following command and start a new chat.

```sh
agent_dir="$HOME/Library/Application Support/Cliphoard Agent"
codex mcp add cliphoard -- "$agent_dir/venv/bin/python" "$agent_dir/server.py"
```

For other stdio clients, use the same absolute Python executable as the command and the absolute server.py path as its only argument.

Ask **“Connect to Cliphoard, search my shared clips for red bicycle, and retrieve the matching note.”** Select the export in the Mac file chooser and enter its passphrase in the native secure field. Each client gets a separate session. `search` returns short previews and IDs. `get_clip` returns the text in pages. `disconnect` clears access immediately. The session also expires after 15 minutes or when the server exits.

Only explicitly tagged eligible records enter the server. The reader excludes rich text, file and image clips, records with any stored sensitivity flag and records flagged by the current detectors. Review your tags before sharing. The model provider used by the client may receive the clips you retrieve. The companion uses memory for the unlocked collection. It leaves the encrypted export in the location you chose. Removing a tag in Cliphoard affects future exports; disconnect, export again and choose the replacement to update the agent's view. To remove the integration, run `codex mcp remove cliphoard`.

## Running the integration test

From the repository root, use a Python 3.13+ virtual environment with the pinned MCP dependency installed. Compile the synthetic archive reader in its bin directory, then run the client test with that environment's Python. The test exercises a real encrypted archive and stdio session, including rejection of unknown flags, untagged IDs, a legacy sensitive source, a wrong passphrase, and trailing bytes.

```sh
swiftc Sources/Cliphoard/Support/HistoryArchive.swift Sources/Cliphoard/Search/Detectors.swift \
  Sources/Cliphoard/Clipboard/ClipItem.swift tools/agent-search/Reader.swift \
  tools/agent-search/tests/main.swift -o "$VIRTUAL_ENV/bin/cliphoard-agent-fixture"
"$VIRTUAL_ENV/bin/python" tools/agent-search/tests/test_stdio.py
```
