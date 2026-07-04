# Cliphoard — Merged Test Plan

Merge of the two reviewer test plans, deduplicated and prioritized. Current state: **44 tests pass** (`swift test` → "Executed 44 tests, with 0 failures") across `CoreTests.swift` and `DeepSearchTests.swift`.

## Current coverage (well covered — do not duplicate)

- `detectKind` classification: plain text; scheme/bare/mailto links; hex colors with the letter-only-word guard (decade/facade/deadbeef); non-colors — `ClassificationTests`.
- `ClipItem` Codable backward/forward compatibility: legacy single-vector fields, missing embeddings key, minimal item, embeddings round-trip — `CodableResilienceTests`.
- Dedup signature stability + kind-specific prefixes (img:/file:/color:) — `SignatureTests`.
- `ClipStore` in-memory behavior: newest-first order, dedup-bump, trim oldest-unpinned, unlimited, pin survives trim & floats front, filter by kind/query/pinned, clearUnpinned, persistence reload, counts — `ClipStoreTests`.
- `Paster` plain strips RTF / rich keeps RTF — `PasterTests`.
- `HashingEmbedder`: determinism, process-independent FNV-1a, L2 normalization, cosine self=1, similar>dissimilar — `EmbeddingTests`.
- Per-model embedding cache & staleness: index attaches vector+5 tags, isStale for unprocessed/other-model, cross-model cache retained, vectors persist+reload non-stale — `IngestIndexingTests` (indirectly exercises `Database.insert`/`loadAll`/`upsertEmbedding` on the hashing path).

## Known weaknesses to fix alongside coverage

- **Test isolation:** several tests read process-wide state (`DeepSearch.level`/`searchMode`, `TagBaskets.activeID`, `EmbedderProvider.active`) from global UserDefaults/statics without resetting; `testHasOneHundredTags` hard-asserts `TagSpace.count==100`, which only holds for general-sized baskets, not developer(45)/everyday(28). Suite is order- and environment-dependent. Fix as P0-adjacent (TP-0) so new assertions are trustworthy.
- The **OgmaEmbedder/CoreML** path cannot be unit-tested without a bundled model (acceptable); the **tokenizer that feeds it can** and currently is not.

---

## Priority P0 — correctness-critical, untested durable/load-bearing paths

### TP-0. Test isolation harness (prerequisite)
- `setUp`/`tearDown` snapshot + restore `deepSearchLevel`, `searchMode`, `activeBasket`, `customTags`.
- `testTagSpaceCountMatchesActiveBasket` — parameterize over all built-in baskets instead of hardcoding 100.
- **File:** shared `Tests/CliphoardTests/TestSupport.swift`.

### TP-1. OgmaTokenizer parity & whitespace (guards AUDIT H3, M3, M5, L8)
- `testEncodeMatchesReferenceIdsForKnownStrings` — golden ids from `reference.json` for several inputs.
- `testEncodeWrapsWithClsAndSepAndOffset` — CLS=9 / SEP=10 boundaries and the `+n_special_tokens` id shift.
- `testEncodeHandlesMultiLineWithoutSpuriousUNK` — `"foo\nbar\tbaz"` produces no per-char UNK run (the H3 regression).
- `testNormalizeStripsAccentsLowercasesAndCollapsesSpaces`.
- `testUnigramFallsBackToUnkForUnknownChars`.
- `testEncodeAppliesMetaspacePrefixPerWord`.
- `testEncodeOOVStringsUrlAndBase64` — OOV-adjacent inputs (UNK-score sensitivity, L8).
- `testInitReturnsNilForMissingOrMalformedTokenizerJson`.
- **File:** `Tests/CliphoardTests/OgmaTokenizerTests.swift` (new) + checked-in `tokenizer.json` fixture.

### TP-2. SQLite Database layer + Float16 BLOB round-trip (guards AUDIT M7, M8, L4, and durability)
- `testFloat16BlobRoundTripWithinTolerance` — `[0.1,0.2,…]` → blob → back, assert ~1e-3.
- `testVectorFromBlobPreservesCount`.
- `testTagsFromTextHandlesEmptyAndMalformed`.
- `testInsertThenLoadAllReturnsEquivalentClip`.
- `testDeleteCascadesEmbeddings` — delete clip, assert embeddings row gone (FK CASCADE).
- `testDeleteUnpinnedKeepsPinned`.
- `testLoadAllOrdersPinnedThenRecency` — pinned DESC, last_used_at DESC.
- `testUpdateMetaPersistsPinAndKindChange`.
- `testOpenCreatesSchemaAndIsIdempotentOnReopen`.
- `testTwoModelReload` — two models' vectors for one clip survive reload (from plan 1).
- **File:** `Tests/CliphoardTests/DatabaseTests.swift` (new).

### TP-3. Legacy history.json → SQLite migration (guards AUDIT robustness-L, data integrity)
- `testMigratesLegacyJSONIntoSqliteAndArchives`.
- `testLegacyVectorFoldedIntoEmbeddingsUnderVectorModel`.
- `testCorruptLegacyJSONIsPreservedNotWiped` — `history.corrupt.json` written, items empty, original kept.
- `testMigrationSkippedWhenDatabaseNonEmpty`.
- `testMigratedJSONNotReimportedOnSecondLaunch`.
- **File:** `Tests/CliphoardTests/MigrationTests.swift` (new).

### TP-4. Degenerate-embedding handling (guards AUDIT H10)
- `testFailedEmbeddingLeavesItemStaleNotCached` — simulated failure (empty vector) is not persisted; item stays stale.
- `testAllZeroOrWrongLengthVectorReportsStale`.
- **File:** `Tests/CliphoardTests/EmbeddingFailureTests.swift` (new). *(Requires the BL-05 change to make failures observable.)*

### TP-5. SQLite write-failure surfacing (guards AUDIT H11)
- `testWriteFailureIsReportedNotSilentlySwallowed` — forced read-only/failed step returns failure to ClipStore.
- `testTransactionRollsBackOnMidBatchError`.
- **File:** `Tests/CliphoardTests/DatabaseTests.swift`. *(Requires BL-06.)*

---

## Priority P1 — important feature/branch coverage

### TP-6. Basket reclassify & tag-index correctness (guards AUDIT M6 partial)
- `testReclassifyAllTagsUpdatesTagsFromCachedVectorWithoutReembedding`.
- `testReclassifyRebuildsTagIndexToNewBasketIds`.
- `testTagVectorCacheInvalidatesWhenBasketFingerprintChanges`.
- `testClassifyTagIdsStayInRangeForSmallBasket` — everyday(28)/developer(45).
- `testCustomBasketPersistsAndBecomesActive`.
- `testReclassifySwitch` (from plan 1).
- **File:** `Tests/CliphoardTests/ReclassifyTests.swift` (new).

### TP-7. QRY/DOC tag-classification consistency (guards AUDIT M6)
- `testIngestTagEqualsQueryTagForAsymmetricEmbedder` — stub embedder distinguishing qry/doc, asserts ingest-tag == `nearestTag` query-tag for representative inputs.
- **File:** `Tests/CliphoardTests/DeepSearchTests.swift` (add stub + test).

### TP-8. Search ranking edge cases (essence threshold/fallback + tag retrieval)
- `testEssenceFallbackReturnsTopKWhenAllBelowThreshold`.
- `testEssenceSubstringBoostOutranksPureCosine`.
- `testEssenceFiltersOutBelowThresholdItems`.
- `testTagSearchRetrievesClipsSharingQueryTag`.
- `testFilteredMatchesFilePathAndColorHex`.
- `testNearestTagPicksLinkTagForUrlQuery`.
- `testEssenceFallback` (from plan 1).
- **File:** `Tests/CliphoardTests/SearchRankingTests.swift` (new).

### TP-9. refineKind promotion (guards content-mutation classification)
- `testRefineKindPromotesWhitespaceFreeTextToLinkWhenTagged`.
- `testRefineKindLeavesMultiWordTextAlone`.
- `testRefineKindDoesNotDemoteNonText`.
- `testRefineKindLink` (from plan 1).
- **File:** `Tests/CliphoardTests/RefineKindTests.swift` (new).

---

## Priority P2 — edge cases / robustness

### TP-10. Capture edge cases (privacy + priority)
- `testCapturePrioritizesFileOverText` — needs a fakeable pasteboard seam.
- `testTransientSkipped` — transient/concealed pasteboard skipped (from both plans).
- `testExcludedBundleIdNotCaptured` — once BL-07 lands.
- `testDetectKindClassifiesIPv4AndIPv6AndLongUrlBoundary`.
- **File:** `Tests/CliphoardTests/CaptureTests.swift` (new) + pasteboard seam.

### TP-11. Concurrency / reindex safety (guards AUDIT M1, M2; after BL-03/BL-14)
- `testConcurrentAddDuringReindexDoesNotWriteStaleSnapshot`.
- `testOverlappingReindexAndReclassifyCoalesceToSinglePass` — `indexing` progress monotonic, ends once.
- **File:** `Tests/CliphoardTests/ReindexConcurrencyTests.swift` (new).

### TP-12. Image payload robustness (guards AUDIT M10, L5)
- `testPersistImageFailureDoesNotStoreUnpastableClip`.
- `testOrphanPngSweepRemovesUnreferencedFiles`.
- **File:** `Tests/CliphoardTests/PayloadTests.swift` (new). *(After BL-18.)*

---

## Notes on sequencing

- TP-0 (isolation) should land first so all subsequent assertions are trustworthy.
- TP-1/TP-2/TP-3 are pure additions testable today (tokenizer needs a fixture; Database/migration need only temp dirs and the hashing path).
- TP-4/TP-5/TP-11/TP-12 depend on the corresponding fixes (BL-05/06/03/14/18) introducing the observable seams.
