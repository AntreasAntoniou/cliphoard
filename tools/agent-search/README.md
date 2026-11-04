# Search and save Cliphoard notes from an agent

This macOS companion works with the encrypted history export in Cliphoard, including TestFlight 1.0.3 (18). Export is available in Free. It exposes seven MCP tools over stdio, with optional note saves and permission choices in build 21. The agent can search and retrieve text you explicitly share. Search matches all query words without regard to case. Plain text, links and color strings are supported.

1. Inspect a clip in Cliphoard and add the custom tag `agent-share` under **Tags → Yours**. In Settings, use **Move to another Mac → Export** and save the encrypted archive.
2. Run `tools/agent-search/install.sh` from a source checkout on the Mac. It requires the Swift compiler and Python 3.14 or newer. If needed set `CLIPHOARD_PYTHON` to the absolute interpreter path. The installer builds the archive reader from Cliphoard's own sources and installs the official Python MCP SDK in a private virtual environment.
3. Register it with an MCP client. For Codex, use the following command and start a new chat.

```sh
agent_dir="$HOME/Library/Application Support/Cliphoard Agent"
codex mcp add cliphoard -- "$agent_dir/venv/bin/python" "$agent_dir/server.py"
```

For other stdio clients, use the same absolute Python executable as the command and the absolute server.py path as its only argument.

Ask **“Connect to Cliphoard, search my shared clips for red bicycle, and retrieve the matching note.”** Select the export in the Mac file chooser and enter its passphrase in the native secure field. Each client gets a separate session. `search` returns short previews and IDs. `get_clip` returns the text in pages. `disconnect` clears access immediately. The session also expires after 15 minutes or when the server exits.

Only explicitly tagged eligible records enter the server. The reader excludes rich text, file and image clips, records with any stored sensitivity flag and records flagged by the current detectors. Review your tags before sharing. The model provider used by the client may receive the clips you retrieve. The companion uses memory for the unlocked collection. It leaves the encrypted export in the location you chose. Removing a tag in Cliphoard affects future exports; disconnect, export again and choose the replacement to update the agent's view. To remove the integration, run `codex mcp remove cliphoard`.

## Running the integration test

From the repository root, use a Python 3.14+ virtual environment with the pinned MCP dependency installed. Compile the synthetic archive reader in its bin directory, then run the client test with that environment's Python. The test exercises a real encrypted archive and stdio session, including rejection of unknown flags, untagged IDs, a legacy sensitive source, a wrong passphrase, and trailing bytes.

```sh
swiftc Sources/Cliphoard/Support/HistoryArchive.swift Sources/Cliphoard/Search/Detectors.swift \
  Sources/Cliphoard/Clipboard/ClipItem.swift tools/agent-search/Reader.swift \
  tools/agent-search/tests/main.swift -o "$VIRTUAL_ENV/bin/cliphoard-agent-fixture"
"$VIRTUAL_ENV/bin/python" tools/agent-search/tests/test_stdio.py
```

## Save agent notes with build 21

Agent saves and their permission choices are available in Free in Cliphoard build 21. Install this companion update, then:

1. In **Cliphoard Settings → AI agents**, leave **Ask every time** selected or choose **Full access**, then enable agent saves and choose a local parent folder. To grant **This session**, select it after the connection is enabled. Cliphoard creates a private session folder there. **Ask every time** and **This session** connections last up to 15 minutes. A new **Full access** connection stays available while Cliphoard is running, until you disconnect or lower its permission.
2. Ask your agent to **connect_writer**. In the native Mac folder chooser, select that new `Cliphoard-Agent-…` session folder.
3. Ask the agent to **save_clip** with a text note. With **Ask every time**, review the request in Cliphoard Settings and click **Save & pin note** or **Decline**. With **This session** or **Full access**, eligible new notes are saved automatically under the permission you chose. Notes flagged as sensitive are declined in every mode.
4. After Cliphoard confirms a durable save, the agent can **search** and **get_clip** that note while it remains among the latest 32 successfully saved notes in this writer connection. The note is pinned and tagged for agents in your local history. Connecting a writer does not share any previous history.

Choose the permission that suits the task:

| Permission | What the agent can do | When it ends |
| --- | --- | --- |
| **Ask every time** — default | Request a new note; you review and approve each Save. | Stays the default until you choose another permission. |
| **This session** | Automatically save eligible new notes in the current Cliphoard session. | Resets when that session ends or its 15-minute limit expires. It is not remembered for the next session. |
| **Full access** | Automatically save eligible new notes continuously while Cliphoard runs, after you explicitly connect. | Disconnect or quit ends the connection. The preference is remembered for future explicitly enabled connections until you choose **Ask every time** or **This session**. |

**Full access means automatic new-note saves, not unrestricted access to Cliphoard.** It never shares live history or allows editing/deleting existing clips. Full access does not connect automatically on app launch: you explicitly enable and select its folder. Choosing Full access during an existing timed connection does not silently extend that connection; disconnect and enable a new one for continuous access. Lowering Full access permission ends an active continuous connection immediately. Ending a connection does not revoke the remembered Full access preference; change the permission in Settings to revoke that preference. The same sensitive-content filter, encrypted transport, request deadlines and durable-save checks apply in every mode.

There are seven tools: `connect`, `connect_writer`, `search`, `get_clip`, `save_clip`, `check_save`, and `disconnect`. The text-note limit is 32 KiB UTF-8, with one save request awaiting a response at a time. The companion retains at most 32 unresolved requests, the latest 32 authenticated completed results, and the latest 32 successfully saved notes for search. Completed saves free capacity, so continuous access does not require reconnecting after 32 notes. If 32 outcomes remain unresolved, reconcile them before submitting more. Older completed results and saved-note cache entries are evicted; this does not delete the actual notes in Cliphoard. The app may briefly apply backpressure to rapid requests while earlier request deadlines remain live. Agent saves do not set your clipboard, change existing notes, delete history, or bypass Pro. They use no model download and no network listener.

If a save reports **unknown**, it might already have committed. Storage being unavailable or a post-commit readback failure is also reported as unknown; it is never evidence that nothing was saved. Use `check_save` with the original `request_id` while the same connection is active. Unresolved request keys are never evicted to make room for new notes; only authenticated definite outcomes free those slots. This reads its authenticated receipt and never sends the note again. Do not automatically call `save_clip` again with the same text. After disconnect/restart, the response keys are gone: inspect Cliphoard or share a fresh encrypted export to establish what was saved before trying again.

`disconnect` clears both the export snapshot and the writer's submitted-note cache, ends its helper, and removes only its known request/receipt files when possible. A request already committing cannot be undone by disconnect. Ending the session in Cliphoard prevents further saves and receipt checks and resets **This session** permission. MCP `disconnect` closes the companion connection without changing your saved permission preference; previously returned text or the agent's own submitted text cannot be recalled from its client/model. The companion's own-note cache clears on connection end or explicit `disconnect`. Timed connections expire within 15 minutes; Full access has no artificial timeout. The native helper checks the original manifest and exact app process identity (kernel start time and boot identity) while idle and before each request. App termination, a stale/recycled PID, or a removed/replaced manifest ends access, and the MCP process clears writer RAM when the helper exits. This liveness check is local, not an authentication defense against a compromised same-user process. Saved history remains in Cliphoard. On a later connection, use a new export to retrieve older saved notes.

Requests are encrypted to the app session's ephemeral key before entering the selected folder; replies authenticate the original session, request, and encrypted content. Private keys stay in RAM. Session metadata is public within your private folder. The transport does not defend against a compromised same-user process that can alter the installed programs, selected folder, or process memory. It has no remote network endpoint; automatic saves require an explicitly connected local session and the permission chosen in Cliphoard.

### Updating an older companion environment

The installer creates a fresh Python 3.14+ environment at a permanent generation path. For an existing installation, stop/disconnect its MCP clients, then run:

```sh
CLIPHOARD_PYTHON=/opt/homebrew/bin/python3.14 tools/agent-search/install.sh --replace-environment
```

The flag confirms that your clients are stopped. The installer builds and verifies the new generation before switching the stable `venv` and `server.py` paths; it preserves the old installation under a uniquely named `backups` folder. It does not execute the old interpreter, remove old exports/history, or kill any client processes. A preparation failure leaves the old installation active and retains the incomplete new generation for inspection. Restart the MCP clients after installation. Python, its SDK, and the helper programs belong to this separately installed companion; none are bundled into the Cliphoard app, and no model weights are bundled.

### Writer tests

Use an isolated Python 3.14+ virtual environment with `mcp==1.30.0` installed. The tests use synthetic notes and disposable folders only; they do not open a real chooser or access your clipboard or history.

```sh
swiftc -parse-as-library Sources/Cliphoard/Support/AgentWriteProtocol.swift \
  Sources/Cliphoard/Support/AgentWriteDirectory.swift tools/agent-search/WriterConnection.swift \
  tools/agent-search/tests/WriterConnectionTests.swift -o "$VIRTUAL_ENV/bin/writer-core-tests"
"$VIRTUAL_ENV/bin/writer-core-tests"
"$VIRTUAL_ENV/bin/python" tools/agent-search/tests/test_writer_stdio.py
```

The composed fixture also drives the actual native controller and asynchronous SQLite save through the MCP client. It substitutes the chooser/user approval and uses a deliberately public AES test key instead of Keychain custody:

```sh
swiftc -parse-as-library Sources/Cliphoard/Support/AgentWriteProtocol.swift \
  Sources/Cliphoard/Support/AgentWriteDirectory.swift Sources/Cliphoard/Support/AgentWriteController.swift \
  Sources/Cliphoard/Clipboard/Database.swift Sources/Cliphoard/Clipboard/ClipItem.swift \
  Sources/Cliphoard/Search/Detectors.swift tools/agent-search/WriterConnection.swift \
  tools/agent-search/tests/ComposedCryptoFixture.swift tools/agent-search/tests/ComposedWriterMain.swift \
  -o "$VIRTUAL_ENV/bin/cliphoard-composed-writer"
"$VIRTUAL_ENV/bin/python" tools/agent-search/tests/test_composed_stdio.py
"$VIRTUAL_ENV/bin/python" tools/agent-search/tests/test_composed_failure.py
"$VIRTUAL_ENV/bin/python" tools/agent-search/tests/test_composed_continuous.py
"$VIRTUAL_ENV/bin/python" tools/agent-search/tests/test_writer_timeout.py
"$VIRTUAL_ENV/bin/python" tools/agent-search/tests/test_writer_expiry.py
"$VIRTUAL_ENV/bin/python" tools/agent-search/tests/test_writer_continuous.py
"$VIRTUAL_ENV/bin/python" tools/agent-search/tests/test_install_environment.py
"$VIRTUAL_ENV/bin/python" tools/agent-search/tests/test_install_rollback.py
```

These are local synthetic integration checks, not a claim that a real owner approved a note in the signed app or that a packaged companion has been installed. Forced process death can leave encrypted transport files; local cleanup is best-effort and cannot undo an already committed note.
