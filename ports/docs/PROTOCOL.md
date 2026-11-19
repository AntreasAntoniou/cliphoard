# Synthetic protocol1

Transport: four-byte **little-endian unsigned byte count**, then exactly that many UTF8 JSON bytes. Valid length1..262144 is checked before body allocation. Clean EOF before a header ends the fixture normally; truncated header/body, zero or oversized length terminate with exit65. Invalid UTF8/JSON, unknown keys/version/op and invalid domain arguments receive fixed errors without echoing input. No paths, SQL, executable commands, network instructions, claimed identities or generic object endpoint exist.

Request envelope, exact keys:

```json
{"version":1,"id":1,"command":{"op":"captureSyntheticText","text":"[CLIPHOARD_SYNTHETIC_V1] generated example"}}
```

Response uses the same version/id, `ok` and either `result` or a fixed `error` code. A malformed envelope has id0. Request IDs are uint32 correlation IDs, never authorization. Item IDs are randomly generated opaque UUIDv4 identifiers and remain stable across an exact-text dedup bump during the process lifetime.

| Operation | Extra command fields | Behavior |
| --- | --- | --- |
| hello | none | Fixture capabilities and bounds; no content |
| captureSyntheticText | text | Exact prefix required; max8192 UTF8 bytes including prefix; nonempty suffix; no NUL. Exact dedup bumps to newest, keeps pin/ID |
| list | limit | Newest first,1..20 results |
| search | query, limit | Case-insensitive substring, max512 UTF8 query bytes;1..20 results |
| select | itemId | Existing UUID only; bumps recency and returns synthetic text |
| pin | itemId, pinned | Existing UUID and boolean; max50 pins |
| clearSynthetic | none | Drops all fixture entries, including pins |
| lock | none | Purges volatile entries and permanently refuses content operations for this process |
| status | none | Lock/count/capacity/persistence-false; no content |

Capacity is200 entries. Trim evicts the oldest unpinned entry; all-pinned capacity refuses growth. Requests are handled serially. Results fit the same262144-byte cap using the actual encoded response envelope, including JSON escaping and worst-case request-ID width. The engine may return fewer than20 rows to respect that cap; the limit is a maximum, not a promised page size. The process handles at most10000 requests and then exits75. There is no persistence and no unlock operation; fixture process restart creates an empty, unlocked synthetic engine. Default execution does not expose any transport.
