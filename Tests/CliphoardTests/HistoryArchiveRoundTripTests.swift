import XCTest
@testable import Cliphoard

/// A whole history out of one store and into another, field by field.
///
/// The fixture is deliberately awkward — all five kinds, three real PNGs, RTF, emoji, CJK,
/// combining marks, an NFC/NFD pair, pins, use counts, multi-word tags, a quarantined clip,
/// a flag bit no build knows, and one `ocrText == ""` beside one `ocrText == nil` — because
/// the fields that quietly fail to travel are never the ordinary ones.
@MainActor
final class HistoryArchiveRoundTripTests: ArchiveTestCase {

    private let passphrase = "a long enough passphrase for the floor"

    private struct Moved {
        let fixture: ArchiveFixture.Standard
        let source: ClipStore
        let destination: ClipStore
        let file: URL
        let report: HistoryArchiveIO.ExportReport
        let tally: ClipStore.ImportTally
    }

    private func sourceStore(named name: String = "source")
        throws -> (ArchiveFixture.Standard, ClipStore) {
        let fixture = ArchiveFixture.standard()
        let dir = directory(name)
        try ArchiveFixture.write(fixture.rows, dismissals: fixture.dismissals,
                                 payloads: fixture.payloads, to: dir)
        let store = ClipStore(directory: dir)
        XCTAssertFalse(store.safeMode, "the fixture store must not be frozen")
        XCTAssertEqual(store.items.count, fixture.rows.count,
                       "the fixture did not load in full")
        return (fixture, store)
    }

    /// Export the fixture and import it into an empty store.
    private func move() throws -> Moved {
        let (fixture, source) = try sourceStore()
        let file = tempRoot.appendingPathComponent("history.cliphoard")
        let report = try source.exportArchive(to: file, passphrase: passphrase).get()
        let destination = ClipStore(directory: directory("destination"))
        XCTAssertTrue(destination.items.isEmpty)
        let staged = try destination.stageImport(from: file, passphrase: passphrase).get()
        let tally = destination.ingestImported(staged)
        XCTAssertNil(tally.refusal, tally.refusal?.message ?? "")
        return Moved(fixture: fixture, source: source, destination: destination, file: file,
                     report: report, tally: tally)
    }

    // MARK: - 11

    func testEveryFieldOfEveryClipSurvivesTheRoundTrip() throws {
        try skipIfKeychainUnreachable()
        let moved = try move()
        XCTAssertEqual(moved.tally.imported, moved.source.items.count)
        XCTAssertEqual(moved.destination.items.count, moved.source.items.count)

        let before = Dictionary(uniqueKeysWithValues: moved.source.items.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: moved.destination.items.map { ($0.id, $0) })
        XCTAssertEqual(Set(before.keys), Set(after.keys), "the id set must be identical")

        for (id, source) in before {
            let arrived = try XCTUnwrap(after[id], "clip \(id) did not arrive")
            XCTAssertEqual(arrived.kind, source.kind, "kind")
            XCTAssertEqual(arrived.text, source.text, "text")
            XCTAssertEqual(arrived.rtf, source.rtf, "rich text")
            XCTAssertEqual(arrived.payloadFile, source.payloadFile, "payload name")
            XCTAssertEqual(arrived.filePath, source.filePath, "file path")
            XCTAssertEqual(arrived.colorHex, source.colorHex, "colour")
            // Raw doubles, bit for bit — the archive carries
            // `timeIntervalSinceReferenceDate` exactly as SQLite stores it, so no
            // formatter is ever in the path.
            XCTAssertEqual(arrived.createdAt.timeIntervalSinceReferenceDate,
                           source.createdAt.timeIntervalSinceReferenceDate,
                           "created_at must survive bit for bit")
            XCTAssertEqual(arrived.lastUsedAt.timeIntervalSinceReferenceDate,
                           source.lastUsedAt.timeIntervalSinceReferenceDate,
                           "last_used_at — an import that bumped this would flatten years "
                           + "of history into today")
            XCTAssertEqual(arrived.pinned, source.pinned, "pin")
            XCTAssertEqual(arrived.sourceApp, source.sourceApp, "source app")
            XCTAssertEqual(arrived.useCount, source.useCount, "use count")
            XCTAssertEqual(arrived.userTags, source.userTags, "user tags")
            XCTAssertEqual(arrived.flags.rawValue, source.flags.rawValue, "flags, raw")
            XCTAssertEqual(arrived.shape, source.shape, "shape")
            XCTAssertEqual(arrived.ocrText, source.ocrText, "recognised text")
        }

        // The unknown high bit, specifically. `Database.insert` writes the raw value
        // verbatim so a flag from a newer build survives a round trip through an older
        // one; an archive that masked it down would be the weakest link in that chain.
        let newer = try XCTUnwrap(after[moved.fixture.unknownFlagID])
        XCTAssertEqual(newer.flags.rawValue, 1 << 30,
                       "a flag bit this build has no name for must arrive untouched")

        // nil versus "" — "never analysed" versus "analysed, deliberately withheld".
        let never = try XCTUnwrap(after[moved.fixture.neverAnalysedImageID])
        XCTAssertNil(never.ocrText,
                     "an unanalysed image must arrive unanalysed, or the destination "
                     + "never looks at it again")
        let withheld = try XCTUnwrap(after[moved.fixture.withheldImageID])
        XCTAssertEqual(withheld.ocrText, "",
                       "a withheld result must arrive as the EMPTY marker, not as nil — "
                       + "nil would re-run recognition on a screenshot whose text the "
                       + "source Mac deliberately refused to store")

        // The NFC/NFD pair must still be two distinct clips.
        XCTAssertEqual(moved.destination.items.filter { $0.text.contains("café")
                                                         || $0.text.contains("cafe\u{0301}") }.count,
                       2, "a composed and a decomposed é are different clips and must stay so")
    }

    // MARK: - 12

    func testImagePayloadsSurviveByteForByteAndAreSealedAtRestOnTheDestination() throws {
        try skipIfKeychainUnreachable()
        let moved = try move()
        let destinationDirectory = moved.destination.storeDirectory
        XCTAssertEqual(moved.tally.payloadsMoved, moved.fixture.payloads.count)

        for (name, original) in moved.fixture.payloads {
            let stored = try Data(contentsOf: destinationDirectory.appendingPathComponent(name))
            XCTAssertTrue(Crypto.isSealed(stored),
                          "\(name) reached the destination as PLAINTEXT — payloads are "
                          + "sealed at rest on both sides, and the envelope is the only "
                          + "place they are ever in the clear")
            XCTAssertEqual(Crypto.open(stored), original,
                           "\(name) did not survive byte for byte")
            XCTAssertEqual(HistoryArchive.sha256Hex(original) + ".png", name,
                           "the payload's NAME is its content hash — that is what makes a "
                           + "swapped image detectable by arithmetic")
            // Regenerated, not carried: 22.6 MB saved and the destination ends up with a
            // thumbnail for every payload rather than for a minority of them.
            let thumb = destinationDirectory.appendingPathComponent(
                (name as NSString).deletingPathExtension + "-thumb.png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: thumb.path),
                          "no thumbnail was regenerated for \(name)")
            XCTAssertTrue(Crypto.isSealed(try Data(contentsOf: thumb)),
                          "the regenerated thumbnail must be sealed too")
        }
        // And the image clips can actually be read back through the normal path.
        for item in moved.destination.items where item.kind == .image {
            XCTAssertNotNil(moved.destination.decryptedPayload(item),
                            "an imported image clip could not be decrypted")
        }
    }

    // MARK: - 13

    func testTheQuarantinedClipIsExportedAndArrivesStillQuarantined() throws {
        try skipIfKeychainUnreachable()
        let moved = try move()
        let arrived = try XCTUnwrap(
            moved.destination.items.first { $0.id == moved.fixture.quarantinedID },
            "the quarantined clip was dropped. It is the USER'S clip; the UI says in plain "
            + "words that it travels, and silently leaving it behind would be the worst "
            + "kind of surprise.")
        XCTAssertTrue(arrived.flags.contains(.quarantined),
                      "it arrived without its quarantine, so the destination would index it")
        XCTAssertTrue(arrived.isIndexVetoed)
        XCTAssertEqual(arrived.text, "hunter2 from the vault")
        XCTAssertEqual(arrived.sourceApp, "com.bitwarden.desktop")
    }

    // MARK: - 14 — the §1.1 regression guard

    func testImageFeaturesSurviveAndEmbeddingsDoNot() throws {
        try skipIfKeychainUnreachable()
        let (fixture, source) = try sourceStore()
        let withPrint = try XCTUnwrap(
            source.items.first { $0.id == fixture.imageIDsWithPrints[0] })
        let originalPrint = try XCTUnwrap(withPrint.imageFeature)
        XCTAssertEqual(originalPrint.vector.count, 768)

        let file = tempRoot.appendingPathComponent("prints.cliphoard")
        let report = try source.exportArchive(to: file, passphrase: passphrase).get()
        XCTAssertEqual(report.imageFeatureCount, 1)
        XCTAssertFalse(report.summary.embeddingsIncluded,
                       "the search index is 71% of the database across five signatures of "
                       + "which the destination uses one — it is recomputed, not carried")
        XCTAssertTrue(report.summary.imageFeaturesIncluded)

        let destination = ClipStore(directory: directory("destination"))
        let staged = try destination.stageImport(from: file, passphrase: passphrase).get()
        // Nothing in the file carries a text embedding.
        XCTAssertTrue(staged.clips.allSatisfy { $0.embeddings.isEmpty },
                      "an embedding travelled — it is tied to the exporting Mac's active "
                      + "embedder signature and means nothing on the destination")
        XCTAssertNil(destination.ingestImported(staged).refusal)

        let arrived = try XCTUnwrap(
            destination.items.first { $0.id == fixture.imageIDsWithPrints[0] })
        let print = try XCTUnwrap(
            arrived.imageFeature,
            "the Vision print did not travel. THIS IS THE WHOLE POINT OF §1.1: a print is "
            + "derived, but the ONLY writer of `imageFeature` — `applyImageUnderstanding` "
            + "— runs behind `needsImageUnderstanding`, which is false forever once "
            + "`ocrText` is non-nil. A faithful import carries `ocrText`, so nothing on "
            + "this Mac would ever recompute it and \"clips that look like this one\" "
            + "would be silently dead for the entire imported history.")
        XCTAssertEqual(print.revision, originalPrint.revision, "the revision must travel: "
                       + "Vision revisions are not comparable — 2048 floats under 1, 768 "
                       + "under 2 — so a print with the wrong revision is worse than none")
        XCTAssertEqual(print.vector, originalPrint.vector)

        // And the fact that makes carrying it necessary, asserted rather than asserted-about.
        XCTAssertFalse(ClipStore.needsImageUnderstanding(arrived),
                       "nothing will ever recompute this print, which is exactly why it "
                       + "had to be in the file")
        XCTAssertNotNil(arrived.ocrText)
        // A clip that arrived with NO recognised text is still picked up, so the export is
        // not quietly turning recognition off for the whole history.
        let never = try XCTUnwrap(
            destination.items.first { $0.id == fixture.neverAnalysedImageID })
        XCTAssertTrue(ClipStore.needsImageUnderstanding(never))
    }

    // MARK: - 15

    func testTheExportWritesNothingToTheStore() throws {
        try skipIfKeychainUnreachable()
        let (_, source) = try sourceStore()
        let dir = source.storeDirectory
        let manager = FileManager.default

        func listing() throws -> [String: Data] {
            var out: [String: Data] = [:]
            for name in try manager.contentsOfDirectory(atPath: dir.path) {
                let url = dir.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                manager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                guard !isDirectory.boolValue else { continue }
                out[name] = (try? Data(contentsOf: url)) ?? Data()
            }
            return out
        }

        let beforeFiles = try listing()
        let beforeIDs = source.items.map(\.id)
        let beforeTexts = source.items.map(\.text)

        // The file itself goes OUTSIDE the store, so its own bytes cannot be mistaken for
        // a write to the history.
        let file = tempRoot.appendingPathComponent("pure-read.cliphoard")
        _ = try source.exportArchive(to: file, passphrase: passphrase).get()

        let afterFiles = try listing()
        XCTAssertEqual(Set(beforeFiles.keys), Set(afterFiles.keys),
                       "the export added or removed a file in the store directory")
        for (name, bytes) in beforeFiles where !name.hasSuffix("-wal") && !name.hasSuffix("-shm") {
            XCTAssertEqual(afterFiles[name], bytes,
                           "\(name) CHANGED. The export must open no write handle, take no "
                           + "transaction and stamp no marker — that is what makes its undo "
                           + "`rm` rather than a promise.")
        }
        XCTAssertEqual(source.items.map(\.id), beforeIDs)
        XCTAssertEqual(source.items.map(\.text), beforeTexts)

        // Re-open the store from scratch: the rows on disk are untouched too.
        let reopened = ClipStore(directory: dir)
        XCTAssertEqual(Set(reopened.items.map(\.id)), Set(beforeIDs))
    }

    /// The export enumerates payloads BY REFERENCE (`payloadFile` on each clip), never the
    /// store directory. The store directory also holds `models/` (385 MB of weights on the
    /// maintainer's Mac) and `unreadable-payloads-archive/` (payloads the app has already
    /// declared unreadable); an export that listed the directory would sweep both in. A
    /// blind verifier proved the behaviour and then proved it was defended by a comment
    /// alone: unioning `contentsOfDirectory` into the reference set left every test green.
    /// The archive is padded to whole 1 MiB chunks, so byte size cannot detect this;
    /// `payloadCount` is the honest instrument.
    func testTheExportCarriesOnlyReferencedPayloadsNeverTheDirectory() throws {
        try skipIfKeychainUnreachable()
        let (fixture, source) = try sourceStore(named: "decoys")
        let dir = source.storeDirectory
        // Two sealed-looking decoys beside the store, plus the two directories the real
        // store carries. None is referenced by any clip.
        for name in ["orphan-a.png", "orphan-b.png"] {
            try Crypto.sealStrict(ArchiveFixture.png(seed: 99))!.write(to: dir.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("models"), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 3_000_000).write(to: dir.appendingPathComponent("models/weights.bin"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("unreadable-payloads-archive"), withIntermediateDirectories: true)
        try ArchiveFixture.png(seed: 7).write(to: dir.appendingPathComponent("unreadable-payloads-archive/old.png"))

        let report = try source.exportArchive(to: tempRoot.appendingPathComponent("decoys.cliphoard"),
                                              passphrase: passphrase).get()
        let referenced = Set(fixture.rows.compactMap(\.payloadFile)).count
        XCTAssertEqual(report.payloadCount, referenced,
                       "the export carried \(report.payloadCount) payloads but only \(referenced) are "
                       + "referenced by a clip — it is enumerating the directory, and on a real "
                       + "store that means model weights and already-unreadable payloads")
    }

}
