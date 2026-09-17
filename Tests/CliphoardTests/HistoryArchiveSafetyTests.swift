import XCTest
@testable import Cliphoard

/// What the archive REFUSES to do, and what it leaves behind when it refuses.
///
/// Every test here is about a failure path, because those are the ones nobody exercises by
/// hand: a wrong passphrase, a frozen store, a short read, a store that cannot decrypt its
/// own rows, an insert that fails halfway through a transaction. Two of them use
/// `Crypto.simulatingEphemeralKey`, the existing seam — without it these skip on every
/// healthy machine, which is precisely how four guards went untested before.
@MainActor
final class HistoryArchiveSafetyTests: ArchiveTestCase {

    private let passphrase = "a long enough passphrase for the floor"

    private func exportFixture(_ name: String = "source")
        throws -> (ArchiveFixture.Standard, ClipStore, URL) {
        let fixture = ArchiveFixture.standard()
        let dir = directory(name)
        try ArchiveFixture.write(fixture.rows, dismissals: fixture.dismissals,
                                 payloads: fixture.payloads, to: dir)
        let store = ClipStore(directory: dir)
        XCTAssertFalse(store.safeMode)
        let file = tempRoot.appendingPathComponent("\(name).cliphoard")
        _ = try store.exportArchive(to: file, passphrase: passphrase).get()
        return (fixture, store, file)
    }

    private func fileSnapshot(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            guard !name.hasSuffix("-wal"), !name.hasSuffix("-shm") else { continue }
            out[name] = (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data()
        }
        return out
    }

    private func entries(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    /// Seven hundred unpinned clips — above `freeHistoryLimit` — plus two pinned ones that are
    /// the OLDEST rows, so only pinning can save them. The 50-clip standard fixture never
    /// exceeds 500 and is therefore structurally unable to check rows, only sentences.
    private func exportHoard(_ name: String)
        throws -> (unpinned: Int, pinned: Int, rows: [ArchiveFixture.Row], file: URL) {
        let unpinned = ClipStore.freeHistoryLimit + 200
        var rows: [ArchiveFixture.Row] = (0..<unpinned).map { n in
            ArchiveFixture.Row(kind: .text, text: "archive clip \(n)",
                               createdAt: 700_000_000 + Double(n),
                               lastUsedAt: 700_000_000 + Double(n))
        }
        for n in 0..<2 {
            rows.append(ArchiveFixture.Row(kind: .text, text: "pinned \(n)",
                                           createdAt: 699_000_000 + Double(n),
                                           lastUsedAt: 699_000_000 + Double(n), pinned: true))
        }
        let dir = directory("\(name)-source")
        try ArchiveFixture.write(rows, to: dir)
        let source = ClipStore(directory: dir)
        XCTAssertEqual(source.items.count, rows.count, "precondition: the hoard loaded whole")
        let file = tempRoot.appendingPathComponent("\(name).cliphoard")
        _ = try source.exportArchive(to: file, passphrase: passphrase).get()
        return (unpinned, 2, rows, file)
    }

    // MARK: - 16

    func testAWrongPassphraseRefusesAndLeavesTheStoreByteIdentical() throws {
        try skipIfKeychainUnreachable()
        let (_, _, file) = try exportFixture()
        let destinationDirectory = directory("destination")
        let destination = ClipStore(directory: destinationDirectory)
        XCTAssertTrue(destination.items.isEmpty)
        let before = try fileSnapshot(destinationDirectory)

        switch destination.stageImport(from: file, passphrase: "the wrong passphrase!!") {
        case .success: XCTFail("a wrong passphrase was ACCEPTED")
        case .failure(let error):
            XCTAssertEqual(error, .wrongPassphraseOrDamaged)
            // Honest wording: at the summary a corrupted header and a wrong passphrase
            // really are indistinguishable, because the header is authenticated only AS
            // the summary's AAD. Saying "wrong passphrase" alone would be a lie.
            XCTAssertTrue(error.message.lowercased().contains("damaged"),
                          "the message must admit the file could also be damaged")
        }

        XCTAssertEqual(try fileSnapshot(destinationDirectory), before,
                       "the store changed after a refused import")
        XCTAssertTrue(entries(destinationDirectory).allSatisfy { !$0.hasPrefix(".import-") },
                      "a staging directory was left behind by a refused import")
        XCTAssertTrue(entries(destinationDirectory)
                        .allSatisfy { !$0.contains("pre-import") },
                      "a snapshot was taken for an import that never started")
        XCTAssertTrue(destination.items.isEmpty)
    }

    // MARK: - 17

    func testImportIntoANonEmptyStoreMergesAndSkipsByIDAndBySignature() throws {
        try skipIfKeychainUnreachable()
        let (fixture, _, file) = try exportFixture()

        // One clip the destination already has BY ID (its content differs — the id is what
        // matches), and one it already has BY CONTENT under a different id. `ClipStore.add`
        // dedups on `signature`, so "no two live clips share a signature" is an invariant
        // the rest of the app assumes; an import that broke it would make
        // `items.first(where: signature ==)` bump an arbitrary one.
        let sharedID = fixture.rows[0].id
        let sharedText = fixture.rows[1].text
        let existing: [ArchiveFixture.Row] = [
            ArchiveFixture.Row(id: sharedID, kind: .text, text: "a different body, same id",
                               createdAt: 600_000_000, lastUsedAt: 600_000_000,
                               pinned: true, useCount: 42, userTags: ["mine"]),
            ArchiveFixture.Row(kind: .text, text: sharedText,
                               createdAt: 600_000_001, lastUsedAt: 600_000_001,
                               pinned: true, useCount: 7, userTags: ["also mine"]),
            ArchiveFixture.Row(kind: .text, text: "something only the destination has",
                               createdAt: 600_000_002, lastUsedAt: 600_000_002),
        ]
        let destinationDirectory = directory("destination")
        try ArchiveFixture.write(existing, to: destinationDirectory)
        let destination = ClipStore(directory: destinationDirectory)
        XCTAssertEqual(destination.items.count, 3)
        let before = Dictionary(uniqueKeysWithValues:
            destination.items.map { ($0.id, ($0.lastUsedAt, $0.pinned, $0.userTags)) })

        let staged = try destination.stageImport(from: file, passphrase: passphrase).get()
        let tally = destination.ingestImported(staged)
        XCTAssertNil(tally.refusal)
        XCTAssertEqual(tally.skippedSameID, 1, "one clip was already here by id")
        XCTAssertEqual(tally.skippedSameContent, 1,
                       "one clip was already here by content — a different count from the "
                       + "one above, because they are different facts and the user should "
                       + "be told which")
        XCTAssertEqual(tally.imported, fixture.rows.count - 2)
        XCTAssertEqual(destination.items.count, 3 + fixture.rows.count - 2)

        for (id, state) in before {
            let still = try XCTUnwrap(destination.items.first { $0.id == id },
                                      "an import DELETED one of the destination's own clips")
            XCTAssertEqual(still.lastUsedAt, state.0,
                           "a merge must not bump the destination's own recency")
            XCTAssertEqual(still.pinned, state.1, "a merge must not touch pins")
            XCTAssertEqual(still.userTags, state.2, "a merge must not touch user tags")
        }
    }

    // MARK: - 18

    func testImportingTheSameFileTwiceIsANoOp() throws {
        try skipIfKeychainUnreachable()
        let (fixture, _, file) = try exportFixture()
        let destinationDirectory = directory("destination")
        let destination = ClipStore(directory: destinationDirectory)

        let first = destination.ingestImported(
            try destination.stageImport(from: file, passphrase: passphrase).get())
        XCTAssertNil(first.refusal)
        XCTAssertEqual(first.imported, fixture.rows.count)
        let afterFirst = destination.items.count
        let payloadsAfterFirst = entries(destinationDirectory).filter { $0.hasSuffix(".png") }

        let second = destination.ingestImported(
            try destination.stageImport(from: file, passphrase: passphrase).get())
        XCTAssertNil(second.refusal)
        XCTAssertEqual(second.imported, 0, "the second import wrote rows")
        XCTAssertEqual(second.skippedSameID, fixture.rows.count)
        XCTAssertEqual(destination.items.count, afterFirst, "the row count moved")
        XCTAssertEqual(second.payloadsMoved, 0)
        XCTAssertEqual(second.payloadsAlreadyPresent, fixture.payloads.count,
                       "payload names are content hashes, so a re-import recognises every "
                       + "image it already holds and re-writes none of them — which on a "
                       + "295 MB file is the whole cost")
        XCTAssertEqual(Set(entries(destinationDirectory).filter { $0.hasSuffix(".png") }),
                       Set(payloadsAfterFirst))
    }

    // MARK: - 19

    func testNoImportedClipGainsATag() throws {
        try skipIfKeychainUnreachable()
        let (fixture, source, file) = try exportFixture()
        let destination = ClipStore(directory: directory("destination"))
        XCTAssertNil(destination.ingestImported(
            try destination.stageImport(from: file, passphrase: passphrase).get()).refusal)

        let before = Dictionary(uniqueKeysWithValues: source.items.map { ($0.id, $0.userTags) })
        for item in destination.items {
            XCTAssertEqual(item.userTags, before[item.id],
                           "an imported clip's tags were rewritten. This is a FAITHFUL "
                           + "MOVE: tagging every row would mutate the exact authored data "
                           + "the feature exists to preserve, and would break idempotence — "
                           + "export → import → export would no longer round-trip, so the "
                           + "strongest test in the suite could not be written.")
            XCTAssertFalse(item.userTags.contains { $0.hasPrefix("imported") },
                           "an `imported-…` marker tag was added")
        }
        _ = fixture
    }

    // MARK: - 20

    func testAFailedInsertMidTransactionLeavesNoRowsAndNoPayloads() throws {
        try skipIfKeychainUnreachable()
        let (_, _, file) = try exportFixture()
        let destinationDirectory = directory("destination")
        let destination = ClipStore(directory: destinationDirectory)
        // STAGED WHILE HEALTHY, committed while the key is ephemeral — so the failure lands
        // where it is interesting: inside the commit, after payloads have already moved.
        let staged = try destination.stageImport(from: file, passphrase: passphrase).get()

        let tally = Crypto.simulatingEphemeralKey {
            destination.ingestImported(staged)
        }
        XCTAssertEqual(tally.imported, 0)
        XCTAssertNotNil(tally.refusal, "a commit that wrote nothing reported success")
        XCTAssertEqual(destination.items.count, 0, "rows survived a rolled-back import")
        XCTAssertEqual(entries(destinationDirectory).filter { $0.hasSuffix(".png") }, [],
                       "payload files survived a rolled-back import. They are moved BEFORE "
                       + "the rows on purpose — the worst case must be a harmless orphan, "
                       + "and an abort has to take them back out.")
        XCTAssertTrue(entries(destinationDirectory).allSatisfy { !$0.hasPrefix(".import-") },
                      "the staging directory was left behind")
        // The database really is empty, not merely reported empty.
        let reopened = ClipStore(directory: destinationDirectory)
        XCTAssertEqual(reopened.items.count, 0)
    }

    // MARK: - 21

    func testSafeModeRefusesBothDirections() throws {
        // (a) As a pure function, with the other terms held healthy — which is the only way
        //     to assert the sqlite term at all: on a machine whose keychain is unreachable
        //     the canary term is unconditionally true and satisfies any end-to-end check by
        //     itself.
        XCTAssertTrue(ClipStore.shouldFreeze(storageComplete: false, decryptionHealthy: true,
                                             itemCount: 50, unreadableCount: 0),
                      "a short read must freeze the store")
        XCTAssertTrue(ClipStore.shouldFreeze(storageComplete: true, decryptionHealthy: false,
                                             itemCount: 50, unreadableCount: 0),
                      "an unhealthy canary must freeze the store")
        XCTAssertFalse(ClipStore.shouldFreeze(storageComplete: true, decryptionHealthy: true,
                                              itemCount: 50, unreadableCount: 1))

        // (b) Through the real gate, using the existing ephemeral-key seam.
        try skipIfKeychainUnreachable()
        let (_, source, file) = try exportFixture()
        let destination = ClipStore(directory: directory("destination"))
        Crypto.simulatingEphemeralKey {
            XCTAssertEqual(HistoryArchiveIO.healthRefusal(safeMode: false), .storeFrozen,
                           "the gate reads `ensureKeyResolved()` — the FUNCTION, not the "
                           + "stale flag, which is set as a side effect of the resolution "
                           + "every guard used to run before")
            switch source.exportArchive(to: tempRoot.appendingPathComponent("never.cliphoard"),
                                        passphrase: passphrase) {
            case .success: XCTFail("an export ran with an ephemeral key")
            case .failure(let error): XCTAssertEqual(error, .storeFrozen)
            }
            switch destination.stageImport(from: file, passphrase: passphrase) {
            case .success: XCTFail("an import ran with an ephemeral key")
            case .failure(let error): XCTAssertEqual(error, .storeFrozen)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("never.cliphoard").path),
            "a refused export left a file behind — a half-written file that looks like a "
            + "backup is worse than no file")
    }

    // MARK: - 22

    func testAnIncompleteLoadRefusesBothDirections() throws {
        try skipIfKeychainUnreachable()
        let (_, _, file) = try exportFixture()

        // A row whose id is not a UUID: the loader SKIPS it silently, so `items.count`
        // comes back one short of the stored count and `loadAllStatus` reports `.short`.
        var rows = ArchiveFixture.standard().rows
        rows[3].rawID = "not-a-uuid-at-all"
        let dir = directory("short")
        try ArchiveFixture.write(rows, to: dir)
        let store = ClipStore(directory: dir)

        XCTAssertFalse(store.storageComplete, "the fixture did not produce a short read")
        XCTAssertNil(store.archiveProof,
                     "a short read must mint no completeness token — the token is the "
                     + "whole mechanism")
        XCTAssertTrue(store.safeMode)

        switch store.exportArchive(to: tempRoot.appendingPathComponent("short.cliphoard"),
                                   passphrase: passphrase) {
        case .success:
            XCTFail("an export ran on a partial read. The user's next action after an "
                    + "export is very often to wipe the old Mac.")
        case .failure(let error):
            XCTAssertEqual(error, .historyNotProvenComplete)
        }
        // And the import direction too: the merge's "skip if the id is already here" is
        // computed from the LOADED id set, so a short read makes that set a PREFIX and
        // merging into it duplicates everything the load failed to see.
        switch store.stageImport(from: file, passphrase: passphrase) {
        case .success: XCTFail("an import ran into an incompletely-read store")
        case .failure(let error):
            XCTAssertTrue(error == .storeFrozen || error == .historyNotProvenComplete,
                          "wrong refusal: \(error.message)")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("short.cliphoard").path))
    }

    /// The completeness TOKEN and the completeness COUNT are two guards, and only one of
    /// them is reachable through `ClipStore`.
    ///
    /// A mutation check found this: deleting `items.count == proof.storedCount` from the
    /// exporter left `testAnIncompleteLoadRefusesBothDirections` green, because a short read
    /// mints no token at all and `exportArchive` refuses on the missing token first. The
    /// count guard is what catches the OTHER case — a token minted by a complete load, and
    /// an `items` array that has moved since — which is real: the orphan-payload sweep in
    /// `ClipStore.init` deletes rows out from under a freshly minted token. So it is
    /// asserted here, against the pure function, rather than left to a path that cannot
    /// reach it.
    func testAnExportOfFewerClipsThanTheProofCountsIsRefused() throws {
        try skipIfKeychainUnreachable()
        let fixture = ArchiveFixture.standard()
        let dir = directory("source")
        try ArchiveFixture.write(fixture.rows, dismissals: fixture.dismissals,
                                 payloads: fixture.payloads, to: dir)
        let store = ClipStore(directory: dir)
        let proof = try XCTUnwrap(store.archiveProof)
        XCTAssertEqual(store.items.count, proof.storedCount)

        let file = tempRoot.appendingPathComponent("short-of-the-proof.cliphoard")
        let result = HistoryArchiveIO.export(
            items: Array(store.items.dropLast()),   // one row fewer than the token counts
            proof: proof, directory: dir, dismissals: [], safeMode: false,
            to: file, passphrase: passphrase, acknowledgingUnreadable: true)
        switch result {
        case .success:
            XCTFail("an export ran with fewer clips than the completeness token counts — "
                    + "the whole point of the token is that the two must agree")
        case .failure(let error):
            XCTAssertEqual(error, .historyNotProvenComplete)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // …and the same call with the full array succeeds, so the refusal above is about
        // the count and not about something else in the arguments.
        switch HistoryArchiveIO.export(items: store.items, proof: proof, directory: dir,
                                       dismissals: [], safeMode: false, to: file,
                                       passphrase: passphrase, acknowledgingUnreadable: true) {
        case .success(let report): XCTAssertEqual(report.clipCount, store.items.count)
        case .failure(let error): XCTFail("the control case failed: \(error.message)")
        }
    }

    // MARK: - 23

    func testExportRefusesWhenAnyClipOrPayloadIsUnreadable() throws {
        try skipIfKeychainUnreachable()
        var fixture = ArchiveFixture.standard()
        // A row sealed under a key this Mac does not hold: the marker is there, nothing on
        // the ring opens it, so `Crypto.open` fails OPEN and hands back the ciphertext.
        let foreign = Data((0..<48).map { _ in UInt8.random(in: 0...255) })
        fixture.rows.append(ArchiveFixture.Row(
            kind: .text, text: "enc1:" + foreign.base64EncodedString(),
            createdAt: 700_000_900, lastUsedAt: 700_000_900, sealText: false))
        // …and an image whose payload FILE will not open, which is a different failure from
        // a row that will not open and is counted separately.
        let brokenPNG = ArchiveFixture.png(seed: 99)
        let brokenName = HistoryArchive.sha256Hex(brokenPNG) + ".png"
        fixture.rows.append(ArchiveFixture.Row(
            kind: .image, text: "Image 24×24", payloadFile: brokenName,
            createdAt: 700_000_901, lastUsedAt: 700_000_901, ocrText: ""))

        let dir = directory("degraded")
        try ArchiveFixture.write(fixture.rows, dismissals: fixture.dismissals,
                                 payloads: fixture.payloads, to: dir)
        try (Data("enc1:".utf8) + foreign).write(to: dir.appendingPathComponent(brokenName))
        let store = ClipStore(directory: dir)
        XCTAssertFalse(store.safeMode, "one unreadable row in fifty must not freeze a store")
        XCTAssertEqual(store.unreadableClipCount, 1)

        let file = tempRoot.appendingPathComponent("degraded.cliphoard")
        switch store.exportArchive(to: file, passphrase: passphrase) {
        case .success:
            XCTFail("an export that silently drops clips was allowed to look complete")
        case .failure(let error):
            XCTAssertEqual(error, .unreadableContent(clips: 1, payloads: 1))
            XCTAssertTrue(error.message.contains("1 clip"), "the message must name the count")
            XCTAssertTrue(error.message.contains("--crypto-diagnostics"),
                          "and must point at the tool that explains why")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // Acknowledged: the rest goes, and the FILE records what did not — so the
        // destination says it too. A partial export must never be able to present itself
        // as complete.
        let report = try store.exportArchive(to: file, passphrase: passphrase,
                                             acknowledgingUnreadable: true).get()
        XCTAssertEqual(report.skippedUnreadableClips, 1)
        XCTAssertEqual(report.skippedUnreadablePayloads, 1)
        XCTAssertEqual(report.summary.skippedUnreadableClips, 1)
        XCTAssertEqual(report.summary.skippedUnreadablePayloads, 1)
        XCTAssertEqual(report.clipCount, fixture.rows.count - 2,
                       "the unreadable row AND the clip whose image will not open are both "
                       + "left out")

        let summary = try HistoryArchiveIO.preview(url: file, passphrase: passphrase).get()
        XCTAssertEqual(summary.skippedUnreadableClips, 1)
        XCTAssertEqual(summary.skippedUnreadablePayloads, 1)
    }

    /// The one clip the app genuinely cannot tell from ciphertext.
    func testAClipWhoseTextBeginsWithTheSealMarkerIsReportedRatherThanSilentlyDropped() throws {
        try skipIfKeychainUnreachable()
        var fixture = ArchiveFixture.standard()
        fixture.rows.append(ArchiveFixture.Row(kind: .text,
                                               text: "enc1:what the user really copied",
                                               createdAt: 700_000_950,
                                               lastUsedAt: 700_000_950))
        let dir = directory("lookalike")
        try ArchiveFixture.write(fixture.rows, payloads: fixture.payloads, to: dir)
        let store = ClipStore(directory: dir)
        XCTAssertNotNil(store.archiveProof)
        // `Crypto.open` peels a layer only when it genuinely DECRYPTS, so this text comes
        // back verbatim — and `isSealed` is a prefix test, so the whole app (the safe-mode
        // counter included) already reads this clip as one it could not decrypt. The export
        // inherits that judgement rather than inventing a second one.
        XCTAssertEqual(store.unreadableClipCount, 1)
        switch store.exportArchive(to: tempRoot.appendingPathComponent("lookalike.cliphoard"),
                                   passphrase: passphrase) {
        case .success: XCTFail("it should have been reported, not silently included")
        case .failure(let error):
            XCTAssertEqual(error, .unreadableContent(clips: 1, payloads: 0),
                           "the user is TOLD, and decides — the alternative is an export "
                           + "that quietly loses a clip or quietly exports ciphertext")
        }
    }

    // MARK: - 24

    func testImportRespectsAndWarnsAboutTheHistoryLimit() throws {
        try skipIfKeychainUnreachable()
        let (fixture, _, file) = try exportFixture()
        let destinationDirectory = directory("destination")
        let destination = ClipStore(directory: destinationDirectory)
        destination.historyLimit = 5

        let staged = try destination.stageImport(from: file, passphrase: passphrase).get()
        let tally = destination.ingestImported(staged, liftLimit: true)
        XCTAssertNil(tally.refusal)
        XCTAssertEqual(tally.imported, fixture.rows.count,
                       "every clip must land — `trim()` deletes rows AND unlinks their "
                       + "payload files, so letting it run here would destroy most of the "
                       + "import and its images with it")
        XCTAssertEqual(destination.items.count, fixture.rows.count)
        // The lift goes as far as the entitlement allows: 0 under Pro, the free ceiling
        // under free. The test fixture is a free store, so the ceiling is the honest answer
        // — and the note must say so rather than claim "Unlimited".
        let expectedLimit = destination.entitlement.isPro ? 0 : ClipStore.freeHistoryLimit
        XCTAssertEqual(destination.historyLimit, expectedLimit,
                       "the limit must be lifted BEFORE the inserts, not after — otherwise "
                       + "the very next copy trims the import that just arrived")
        let note = try XCTUnwrap(tally.historyLimitNote, "the user was not told")
        XCTAssertTrue(note.contains("5"), "the note must name the old limit")
        if destination.entitlement.isPro {
            XCTAssertTrue(note.contains("Unlimited"))
        } else {
            XCTAssertTrue(note.contains("\(ClipStore.freeHistoryLimit)") && !note.contains("Unlimited"),
                          "a free build must be told the ceiling, never told 'Unlimited': \(note)")
        }
        XCTAssertEqual(entries(destinationDirectory).filter { $0.hasSuffix(".png") }.count,
                       fixture.payloads.count * 2,
                       "every payload and its regenerated thumbnail must still be there")

        // The other choice: keep the limit. What fits lands; the rest stays in the file, and
        // the note says so — nothing is imported only to be trimmed by the next copy.
        let other = ClipStore(directory: directory("kept-limit"))
        other.historyLimit = 5
        let staged2 = try other.stageImport(from: file, passphrase: passphrase).get()
        let kept = other.ingestImported(staged2, liftLimit: false)
        XCTAssertNil(kept.refusal)
        let pinnedInFile = fixture.rows.filter(\.pinned).count
        XCTAssertEqual(other.historyLimit, 5, "the limit must never be changed silently")
        XCTAssertEqual(other.items.filter { !$0.pinned }.count, 5,
                       "nothing lands that the next capture would evict")
        XCTAssertEqual(kept.imported, 5 + pinnedInFile)
        XCTAssertEqual(kept.leftInFile, fixture.rows.count - pinnedInFile - 5)
        XCTAssertTrue(try XCTUnwrap(kept.historyLimitNote).contains("stay in the file"))
    }

    // MARK: - 25

    func testTwoExportsOfTheSameStoreDifferFromOffsetSixteenOnward() throws {
        try skipIfKeychainUnreachable()
        let fixture = ArchiveFixture.standard()
        let dir = directory("source")
        try ArchiveFixture.write(fixture.rows, dismissals: fixture.dismissals,
                                 payloads: fixture.payloads, to: dir)
        let source = ClipStore(directory: dir)

        let first = tempRoot.appendingPathComponent("first.cliphoard")
        let second = tempRoot.appendingPathComponent("second.cliphoard")
        _ = try source.exportArchive(to: first, passphrase: passphrase).get()
        _ = try source.exportArchive(to: second, passphrase: passphrase).get()
        let a = try Data(contentsOf: first)
        let b = try Data(contentsOf: second)

        XCTAssertEqual(a.count, b.count,
                       "the summary is padded to a fixed 1024 bytes and the body is padded "
                       + "to a whole chunk, so two exports of one store are the same size "
                       + "whatever the machine name or the clip count")
        XCTAssertEqual(a.prefix(16), b.prefix(16),
                       "magic, version, algorithm ids and the round count are the same")
        XCTAssertNotEqual(Data(a[16..<32]), Data(b[16..<32]),
                          "the SALT must be fresh per export. A hard-coded salt would make "
                          + "one dictionary do for every file anyone ever exports.")
        XCTAssertNotEqual(Data(a[32..<36]), Data(b[32..<36]),
                          "the nonce prefix must be fresh too — a counter-only nonce would "
                          + "reuse (key, nonce) pairs across two exports of one store")
        XCTAssertNotEqual(Data(a.suffix(64)), Data(b.suffix(64)),
                          "and therefore every ciphertext byte differs")

        // Both open, and both produce the same store.
        for (n, file) in [first, second].enumerated() {
            let destination = ClipStore(directory: directory("destination-\(n)"))
            XCTAssertNil(destination.ingestImported(
                try destination.stageImport(from: file, passphrase: passphrase).get()).refusal)
            XCTAssertEqual(Set(destination.items.map(\.id)), Set(source.items.map(\.id)))
            XCTAssertEqual(Set(destination.items.map(\.text)), Set(source.items.map(\.text)))
        }
    }

    /// `ClipStore.init` re-mints `historyProof` after the orphan sweep deletes rows. Without
    /// it, `storedCount` describes a database that no longer exists, `items.count ==
    /// proof.storedCount` is false for the rest of the process, and the export refuses on
    /// a store that is perfectly whole. The maintainer's own store has swept orphans, so
    /// this is the path every real export takes. A blind verifier reverted the hunk and
    /// found 666 tests still green: the fix shipped with nothing pinning it.
    func testAnExportSucceedsAfterTheLaunchSweepDeletedAnOrphanedImageRow() throws {
        try skipIfKeychainUnreachable()
        let fixture = ArchiveFixture.standard()
        var rows = fixture.rows
        // An image row whose payload file does NOT exist on disk: the launch sweep deletes
        // it (`orphanedImageRows`), which is the exact moment the proof goes stale.
        rows.append(ArchiveFixture.Row(kind: .image, text: "Image 24×24", payloadFile: "ghost.png",
                                       createdAt: 700_000_999, lastUsedAt: 700_000_999))
        let dir = directory("swept")
        try ArchiveFixture.write(rows, dismissals: fixture.dismissals, payloads: fixture.payloads, to: dir)
        let store = ClipStore(directory: dir)
        XCTAssertFalse(store.safeMode)
        XCTAssertEqual(store.items.count, fixture.rows.count, "the sweep must have removed exactly the ghost row")

        switch store.exportArchive(to: tempRoot.appendingPathComponent("swept.cliphoard"), passphrase: passphrase) {
        case .success(let report):
            XCTAssertEqual(report.clipCount, fixture.rows.count)
        case .failure(let error):
            XCTFail("the export refused on a whole store after the launch sweep: \(error). "
                    + "historyProof was not re-minted after orphanedImageRows deleted a row.")
        }
    }


    /// The same import under Pro lifts the limit to Unlimited — the two rulings agree at
    /// the seam: clamp for free, never delete for anyone, always say what happened.
    func testImportUnderProLiftsTheLimitToUnlimited() throws {
        try skipIfKeychainUnreachable()
        let (fixture, _, file) = try exportFixture("pro-source")
        let destination = ClipStore(directory: directory("pro-dest"))
        destination.entitlement = .pro(orderID: "test", issued: Date())
        destination.historyLimit = 5
        let staged = try destination.stageImport(from: file, passphrase: passphrase).get()
        let tally = destination.ingestImported(staged, liftLimit: true)
        XCTAssertNil(tally.refusal)
        XCTAssertEqual(tally.imported, fixture.rows.count)
        XCTAssertEqual(destination.historyLimit, 0, "Pro lifts to Unlimited")
        XCTAssertTrue(tally.historyLimitNote?.contains("Unlimited") ?? false)
    }

    // MARK: - The free ceiling, in ROWS (Argus-27)

    /// A free import above the ceiling landed every row and left the stored limit at 500, so
    /// the FIRST CAPTURE AFTERWARDS deleted 201 rows — under a preview that said "Nothing is
    /// deleted". The 50-clip fixture cannot see this; a 702-clip hoard can.
    func testAFreeImportAboveTheCeilingIsNotDestroyedByTheNextCapture() throws {
        try skipIfKeychainUnreachable()
        let hoard = try exportHoard("hoard")
        let ceiling = ClipStore.freeHistoryLimit
        let destination = ClipStore(directory: directory("hoard-free-dest"))
        try XCTSkipIf(destination.safeMode, "frozen store here")
        destination.entitlement = .free(reason: nil)
        destination.historyLimit = 200

        let staged = try destination.stageImport(from: hoard.file, passphrase: passphrase).get()
        let tally = destination.ingestImported(staged, liftLimit: true)
        XCTAssertNil(tally.refusal)

        // 1. The limit went UP to the ceiling and no further — never 0, never left at 200.
        XCTAssertEqual(destination.historyLimit, ceiling, "lifted as far as free allows, no further")

        // 2. What landed FITS, and every pinned clip landed on top of it.
        let unpinnedLanded = destination.items.filter { !$0.pinned }
        XCTAssertEqual(unpinnedLanded.count, ceiling,
                       "\(unpinnedLanded.count) unpinned rows against a limit of \(ceiling): the "
                       + "first capture would evict \(max(0, unpinnedLanded.count + 1 - ceiling))")
        XCTAssertEqual(destination.items.filter(\.pinned).count, hoard.pinned,
                       "pinned clips always land and never count")
        XCTAssertEqual(tally.imported, ceiling + hoard.pinned)
        XCTAssertEqual(tally.leftInFile, hoard.unpinned - ceiling)

        // 3. The NEWEST landed, by lastUsedAt — trim's own order.
        let newest = hoard.rows.filter { !$0.pinned }.sorted { $0.lastUsedAt > $1.lastUsedAt }
        XCTAssertEqual(Set(unpinnedLanded.map(\.id)), Set(newest.prefix(ceiling).map(\.id)))

        // 4. The sentence is true.
        let note = try XCTUnwrap(tally.historyLimitNote)
        XCTAssertFalse(note.contains("Unlimited"), note)
        XCTAssertTrue(note.contains("\(ceiling)") && note.contains("\(hoard.unpinned - ceiling)"), note)

        // 5. THE DEFECT, in rows: the first capture afterwards.
        let landed = Set(destination.items.map(\.id))
        let before = destination.items.count
        destination.add(ClipItem(kind: .text, text: "the first clip copied after the import"))
        let gone = landed.subtracting(destination.items.map(\.id))
        XCTAssertEqual(destination.items.count, before,
                       "the capture changed the row count by \(destination.items.count - before)")
        XCTAssertEqual(gone.count, 1, "the first capture after the import deleted \(gone.count) "
                       + "clip(s); a full history rolls off exactly one")
        XCTAssertEqual(gone, [newest[ceiling - 1].id], "and it is the oldest unpinned one")
        XCTAssertEqual(destination.items.filter(\.pinned).count, hoard.pinned, "a pinned clip was trimmed")

        // 6. The file is the user's data and is untouched.
        XCTAssertEqual(try HistoryArchiveIO.preview(url: hoard.file, passphrase: passphrase).get()
                           .clipCount, hoard.unpinned + hoard.pinned)
    }

    /// The worse bug nobody reported: a stored limit ABOVE the ceiling, left by a lapsed Pro
    /// or a 1.0.0 build. The old C3 wrote the clamped 500 through the gated setter, which
    /// trims as it writes — deleting the user's own clips BEFORE the import wrote a row.
    func testAFreeImportNeverLowersAStoredLimitAboveTheCeiling() throws {
        try skipIfKeychainUnreachable()
        let (fixture, _, file) = try exportFixture("small")      // 4 pinned, 3 image clips
        let stored = ClipStore.freeHistoryLimit + 220             // 720
        let existingCount = stored - 2                            // room for exactly 2
        let existing: [ArchiveFixture.Row] = (0..<existingCount).map { n in
            ArchiveFixture.Row(kind: .text, text: "mine \(n)",
                               createdAt: 600_000_000 + Double(n), lastUsedAt: 600_000_000 + Double(n))
        }
        let dir = directory("grandfathered")
        try ArchiveFixture.write(existing, to: dir)
        UserDefaults.standard.set(stored, forKey: "historyLimit")   // RAW — the setter would clamp it
        let store = ClipStore(directory: dir)
        try XCTSkipIf(store.safeMode, "frozen store here")
        store.entitlement = .free(reason: nil)
        XCTAssertEqual(store.items.count, existingCount, "precondition: init does not trim")
        XCTAssertEqual(store.historyLimit, stored, "precondition")

        let staged = try store.stageImport(from: file, passphrase: passphrase).get()
        let tally = store.ingestImported(staged, liftLimit: true)
        XCTAssertNil(tally.refusal)
        XCTAssertEqual(store.historyLimit, stored,
                       "the import REWROTE a stored limit through the clamp — and the setter trims as it writes")
        XCTAssertEqual(Set(existing.map(\.id)).intersection(store.items.map(\.id)).count, existingCount,
                       "the import DELETED clips the user already had")
        let pinned = fixture.rows.filter(\.pinned).count
        XCTAssertEqual(tally.imported, 2 + pinned)
        XCTAssertEqual(store.items.filter { !$0.pinned }.count, stored)
        XCTAssertEqual(tally.leftInFile, fixture.rows.count - pinned - 2)
        // The 3 image clips rank 4th–6th newest, so they stayed in the file: no orphan payload.
        XCTAssertEqual(entries(dir).filter { $0.hasSuffix(".png") }.count, 0,
                       "an image clip that stayed in the file left its payload behind")
        store.add(ClipItem(kind: .text, text: "after"))
        XCTAssertEqual(store.items.filter { !$0.pinned }.count, stored, "a full history rolls off exactly one")
        XCTAssertEqual(store.items.filter(\.pinned).count, pinned)
    }

    /// Pro is untouched by the fit rule: everything lands, the limit is really off, and the
    /// next capture deletes nothing.
    func testTheSameImportUnderProLandsEverythingAndTheNextCaptureDeletesNothing() throws {
        try skipIfKeychainUnreachable()
        let hoard = try exportHoard("hoard-pro")
        let destination = ClipStore(directory: directory("hoard-pro-dest"))
        try XCTSkipIf(destination.safeMode, "frozen store here")
        destination.entitlement = .pro(orderID: "test", issued: Date())
        destination.historyLimit = 200
        let staged = try destination.stageImport(from: hoard.file, passphrase: passphrase).get()
        let tally = destination.ingestImported(staged, liftLimit: true)
        XCTAssertNil(tally.refusal)
        XCTAssertEqual(destination.historyLimit, 0, "Pro really turns the limit off")
        XCTAssertEqual(destination.items.count, hoard.unpinned + hoard.pinned)
        XCTAssertEqual(tally.leftInFile, 0)
        XCTAssertTrue(try XCTUnwrap(tally.historyLimitNote).contains("Unlimited"))
        destination.add(ClipItem(kind: .text, text: "after"))
        XCTAssertEqual(destination.items.count, hoard.unpinned + hoard.pinned + 1)
    }

    /// The rule as arithmetic, the ratchet, every sentence, and both surfaces reading the plan.
    func testTheImportPlanNeverLetsAFreeBuildAskForMoreAndEverySentenceIsTrue() throws {
        let free = Entitlement.free(reason: nil)
        let pro = Entitlement.pro(orderID: "test", issued: Date())
        let ceiling = ClipStore.freeHistoryLimit
        func plan(_ stored: Int, _ here: Int, _ e: Entitlement, lift: Bool = true) -> ClipStore.ImportPlan {
            ClipStore.importPlan(limitBefore: stored, unpinnedHere: here, lift: lift, entitlement: e)
        }
        XCTAssertEqual(plan(200, 100, free).limitAfter, ceiling)          // up to the ceiling
        XCTAssertEqual(plan(200, 100, free).room, ceiling - 100)
        XCTAssertEqual(plan(720, 700, free).limitAfter, 720)              // never down
        XCTAssertEqual(plan(720, 700, free).room, 20)
        XCTAssertEqual(plan(5000, 600, free).limitAfter, 5000)
        XCTAssertEqual(plan(0, 5000, free).limitAfter, 0)                 // grandfathered 0 honoured
        XCTAssertNil(plan(0, 5000, free).room)
        XCTAssertEqual(plan(200, 600, free).limitAfter, 200)              // a raise that would trim: no
        XCTAssertEqual(plan(200, 600, free).room, 0)
        XCTAssertFalse(plan(ceiling, 0, free).lifts)                      // nothing to offer at the ceiling
        XCTAssertEqual(plan(200, 100, pro).limitAfter, 0)
        XCTAssertNil(plan(200, 100, pro).room)
        XCTAssertEqual(plan(200, 100, pro, lift: false).room, 100)

        // THE RATCHET: no free path raises the stored limit past max(stored, ceiling), or to 0.
        for stored in [1, 100, 200, 500, 1000, 5000] {
            for here in [0, 100, 600, 6000] {
                let p = plan(stored, here, free)
                XCTAssertNotEqual(p.limitAfter, 0, "free obtained unlimited history (stored \(stored), here \(here))")
                XCTAssertLessThanOrEqual(p.limitAfter, max(stored, ceiling))
                XCTAssertGreaterThanOrEqual(p.limitAfter, stored, "an import lowered a limit")
            }
        }

        // The sentences.
        let f = plan(200, 100, free)
        let before = try XCTUnwrap(f.preview(incomingUnpinned: 700))
        XCTAssertFalse(before.contains("Unlimited"), before)
        XCTAssertTrue(before.contains("\(ceiling)") && before.contains("\(ceiling - 100)"), before)
        XCTAssertTrue(before.contains("nothing already here is deleted"), before)
        let after = try XCTUnwrap(f.outcome(admittedUnpinned: ceiling - 100, leftInFile: 300))
        XCTAssertTrue(after.contains("\(ceiling - 100)") && after.contains("300") && !after.contains("Unlimited"), after)
        XCTAssertFalse(f.refusal(incomingUnpinned: 700).contains("--set-unlimited"),
                       "a free build must not be told a flag that does not do what it says")
        XCTAssertTrue(plan(200, 100, pro, lift: false).refusal(incomingUnpinned: 700).contains("--set-unlimited"))
        XCTAssertTrue(try XCTUnwrap(plan(200, 100, pro).preview(incomingUnpinned: 700)).contains("turned off"))
        XCTAssertNil(plan(200, 100, pro, lift: false).preview(incomingUnpinned: 50), "nothing to say when it fits")
        XCTAssertNil(plan(200, 100, pro, lift: false).outcome(admittedUnpinned: 50, leftInFile: 0))

        // Both surfaces read the plan rather than re-deriving the rule.
        let main = try source("Sources/Cliphoard/App/Main.swift")
        XCTAssertFalse(main.contains("Re-run with --set-unlimited to turn the limit off, or"),
                       "under free that flag set 500 — --accept-trim wearing a different word")
        XCTAssertTrue(main.contains("ClipStore.importPlan("))
        let section = try source("Sources/Cliphoard/UI/MoveToNewMacSection.swift")
        XCTAssertFalse(section.contains("deletes most of this import"),
                       "the old toggle promised a free build could turn the limit off")
        let box = try XCTUnwrap(body(of: "private func previewBox", in: section))
        XCTAssertTrue(box.contains(".preview(incomingUnpinned:") && box.contains("offersLift"))
    }

    /// A grandfathered limit is honoured even when there is ROOM. The old C3 would have
    /// rewritten 720 as 500 through the clamp — no deletion that day, but every capture after
    /// it would trim at 500 instead of 720, quietly costing a lapsed Pro 220 clips of capacity.
    /// (When the store is full, the raise-may-not-delete guard blocks the lowering too; this
    /// is the case only `max(ceiling, stored)` protects.)
    func testAFreeImportKeepsAGrandfatheredLimitWhenThereIsRoom() throws {
        try skipIfKeychainUnreachable()
        let (fixture, _, file) = try exportFixture("roomy")
        let stored = ClipStore.freeHistoryLimit + 220
        let existing: [ArchiveFixture.Row] = (0..<10).map { n in
            ArchiveFixture.Row(kind: .text, text: "mine \(n)",
                               createdAt: 600_000_000 + Double(n), lastUsedAt: 600_000_000 + Double(n))
        }
        let dir = directory("grandfathered-roomy")
        try ArchiveFixture.write(existing, to: dir)
        UserDefaults.standard.set(stored, forKey: "historyLimit")   // RAW — the setter would clamp it
        let store = ClipStore(directory: dir)
        try XCTSkipIf(store.safeMode, "frozen store here")
        store.entitlement = .free(reason: nil)
        let staged = try store.stageImport(from: file, passphrase: passphrase).get()
        let tally = store.ingestImported(staged, liftLimit: true)
        XCTAssertNil(tally.refusal)
        XCTAssertEqual(store.historyLimit, stored, "a limit above the ceiling was LOWERED by an import")
        XCTAssertEqual(tally.imported, fixture.rows.count, "everything fits under \(stored)")
        XCTAssertEqual(tally.leftInFile, 0)
        XCTAssertNil(tally.historyLimitNote, "nothing about the limit needed saying: \(tally.historyLimitNote ?? "")")
        XCTAssertEqual(store.items.count, existing.count + fixture.rows.count)
    }

}
