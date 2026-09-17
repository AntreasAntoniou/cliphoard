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
        let tally = destination.ingestImported(staged, setUnlimited: true)
        XCTAssertNil(tally.refusal)
        XCTAssertEqual(tally.imported, fixture.rows.count,
                       "every clip must land — `trim()` deletes rows AND unlinks their "
                       + "payload files, so letting it run here would destroy most of the "
                       + "import and its images with it")
        XCTAssertEqual(destination.items.count, fixture.rows.count)
        XCTAssertEqual(destination.historyLimit, 0,
                       "the limit must be lifted BEFORE the inserts, not after — otherwise "
                       + "the very next copy trims the import that just arrived")
        let note = try XCTUnwrap(tally.historyLimitNote, "the user was not told")
        XCTAssertTrue(note.contains("5"), "the note must name the old limit")
        XCTAssertEqual(entries(destinationDirectory).filter { $0.hasSuffix(".png") }.count,
                       fixture.payloads.count * 2,
                       "every payload and its regenerated thumbnail must still be there")

        // The other choice: keep the limit, and say plainly what will happen.
        let other = ClipStore(directory: directory("kept-limit"))
        other.historyLimit = 5
        let staged2 = try other.stageImport(from: file, passphrase: passphrase).get()
        let kept = other.ingestImported(staged2, setUnlimited: false)
        XCTAssertNil(kept.refusal)
        XCTAssertEqual(kept.imported, fixture.rows.count)
        XCTAssertEqual(other.historyLimit, 5, "the limit must never be changed silently")
        XCTAssertTrue(try XCTUnwrap(kept.historyLimitNote).contains("WARNING"))
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
}
