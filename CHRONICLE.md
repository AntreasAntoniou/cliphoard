# CHRONICLE

Curated narrative for this project. The complete trace — every file, command, and
prompt, with full content — lives in the chronicle ledger; `chron resume` reads it back.

**Append only.** Corrections reference the entry they supersede; nothing is ever edited.

---


## [2026-08-06T14:58Z-ACN5] DECISION — Wave 3: integrate UI + harness, REJECT the vocab item

- **State reading:** INTENTIONAL: the 4 abstract axes are still present on main after Wave 3 — they are NOT forgotten, they are deliberately left until Wave 4 calibration decides the replacement. The Coarse Topic lane is NOT yet in the tree.
- **Why:** Adversary measured that vocab-B removed 3 abstract axes but added new 8-wide axes still scored by argmax-against-bare-tag-word, and chip count per overlay went UP (6->8). That reintroduces the exact failure the 202-clip audit condemned (Intent/Sensitivity margin 0.03-0.04 on both ogma-small and gemma-300m). Its one good piece, TagSpace.classifyTopic with correct veto handling + dual gate, is dead code until calibration enables it, so holding it costs nothing.


## [2026-08-06T14:58Z-ZEQ4] NOTE — Fixing the Wave-3 backfill one-shot flag: it is set outside the db transaction, so a rolled-back backfill is marked complete forever and pre-detector secrets are never re-scanned or purged from the CoreML index.



## [2026-08-06T15:24Z-91RG] DECISION — Root-cause fix: SE key must never be regenerated over an existing blob

- **State reading:** BUG, now fixed in code: 202 clips' TEXT is permanently unreadable — the key that sealed them no longer exists (no Time Machine, no duplicate keychain entry, no history.json archive). INTENTIONAL going forward: on unrestorable blob we fail closed to the legacy key rather than mint a new one. DB backed up at ~/Library/Application Support/Ditto/ditto.sqlite.backup-20260806-160731 (still encrypted with the lost key).
- **Why:** secureEnclaveKey() fell into its create-branch whenever restore failed, and storeBlob deletes-then-adds, so it silently destroyed the only key that could open already-sealed rows. Verified: db-se-key-v2 cdat=mdat=2026-08-06T02:25:54Z while 202 clips (all created Aug 5 or earlier) fail to open with BOTH the current SE key and the June legacy key; the 30 clips created today open fine.

