import XCTest
import CryptoKit
@testable import Cliphoard

/// The `.cliphoard` container, asserted at the byte level and with no store anywhere.
///
/// Every test here builds an archive in memory, damages it in one specific way, and checks
/// that the reader refuses. That is only possible because `HistoryArchive` is pure — no
/// `ClipStore`, no `Database`, no keychain — so these run on any machine, in any state, in
/// milliseconds. The same reasoning that made `HistoryReaper`'s refusals pure functions:
/// a rule that can only be exercised in its safe state is not a tested rule.
@MainActor
final class HistoryArchiveFormatTests: XCTestCase {

    private typealias ArchiveErrorAlias = HistoryArchive.ArchiveError

    private static let passphrase = "correct horse battery staple"
    /// Fixed so the derived key can be reused across the file — a real export always uses
    /// fresh CSPRNG bytes, and `testTwoExportsOfTheSameStoreDifferFromOffsetSixteenOnward`
    /// is where that is asserted.
    private static let salt = Data(repeating: 0x5A, count: HistoryArchive.kdfSaltLength)
    private static let otherSalt = Data(repeating: 0xA5, count: HistoryArchive.kdfSaltLength)
    private static let noncePrefix = Data([0x01, 0x02, 0x03, 0x04])
    private static let otherNoncePrefix = Data([0x09, 0x08, 0x07, 0x06])
    private static let iterations = HistoryArchive.kdfRoundsFloor

    // MARK: - Building and reading archives in memory

    private func makeSummary(payloads: [(String, Data)]) -> HistoryArchive.Summary {
        HistoryArchive.Summary(
            appVersion: "1.0.1", exportedAt: "2026-09-17T11:04:02Z",
            machineName: "Test Mac", clipCount: 3, byKind: ["text": 3], pinnedCount: 0,
            oldestCreatedAt: 700_000_000, newestCreatedAt: 700_000_100,
            payloadCount: payloads.count,
            payloadBytes: payloads.reduce(0) { $0 + $1.1.count },
            imageFeatureCount: 0, dismissalCount: 0, embeddingsIncluded: false,
            imageFeaturesIncluded: true, skippedUnreadableClips: 0,
            skippedUnreadablePayloads: 0)
    }

    private func build(chunkSize: UInt32 = HistoryArchive.minChunkSize,
                       salt: Data? = nil,
                       noncePrefix: Data? = nil,
                       iterations: UInt32? = nil,
                       payloads: [(String, Data)] = [],
                       manifestMutation: ((inout HistoryArchive.Summary) -> Void)? = nil)
        throws -> Data {
        let salt = salt ?? Self.salt
        let prefix = noncePrefix ?? Self.noncePrefix
        let rounds = iterations ?? Self.iterations
        let key = try XCTUnwrap(HistoryArchive.deriveKey(passphrase: Self.passphrase,
                                                         salt: salt, iterations: rounds))
        let header = HistoryArchive.Header(kdfIterations: rounds, kdfSalt: salt,
                                           noncePrefix: prefix, chunkSize: chunkSize)
        let summary = makeSummary(payloads: payloads)
        var manifest = summary
        manifestMutation?(&manifest)

        var out = Data()
        let headerBytes = header.encoded
        out.append(headerBytes)
        let nonce = try AES.GCM.Nonce(data: prefix + HistoryArchive.be64(0))
        let sealed = try AES.GCM.seal(try summary.paddedPlaintext(), using: key, nonce: nonce,
                                      authenticating: headerBytes)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)

        let chunks = HistoryArchive.ChunkWriter(key: key, noncePrefix: prefix,
                                                header: headerBytes,
                                                chunkSize: Int(chunkSize),
                                                sink: { out.append($0) })
        let records = HistoryArchive.RecordWriter(chunks: chunks)
        let encoder = HistoryArchive.Summary.encoder()
        try records.write(.manifest, name: "manifest.json", body: manifest.json)
        for n in 0..<3 {
            let clip = HistoryArchive.Clip(
                id: UUID().uuidString, kind: "text", text: "clip \(n)", rtfB64: nil,
                payloadFile: nil, filePath: nil, colorHex: nil,
                createdAt: 700_000_000 + Double(n), lastUsedAt: 700_000_000 + Double(n),
                pinned: false, sourceApp: nil, useCount: 0, userTags: [], flags: 0,
                shape: nil, ocrText: nil)
            try records.write(.clip, name: clip.id, body: try encoder.encode(clip))
        }
        for (name, bytes) in payloads {
            try records.write(.payload, name: name, body: bytes)
        }
        try records.finishWithPadAndEnd()
        return out
    }

    /// Where every chunk frame starts, and how long it is.
    private struct Frame { let offset: Int; let total: Int; let length: Int; let isFinal: Bool }

    private func frames(in data: Data) -> [Frame] {
        var out: [Frame] = []
        var i = HistoryArchive.headerLength + Int(HistoryArchive.summaryLength)
        while i + 5 <= data.count {
            let length = Int(HistoryArchive.readBE32(data, at: i))
            let isFinal = data[data.startIndex + i + 4] == 1
            let total = 5 + length + 16
            out.append(Frame(offset: i, total: total, length: length, isFinal: isFinal))
            i += total
            if isFinal { break }
        }
        return out
    }

    @discardableResult
    private func readRecords(_ data: Data,
                             passphrase: String = HistoryArchiveFormatTests.passphrase) throws
        -> [HistoryArchive.RawRecord] {
        let opened = try HistoryArchive.open(source: HistoryArchive.DataByteSource(data),
                                             passphrase: passphrase)
        let reader = HistoryArchive.RecordReader(
            chunks: HistoryArchive.ChunkReader(source: opened.source, key: opened.key,
                                               header: opened.header))
        var out: [HistoryArchive.RawRecord] = []
        while true {
            let record = try reader.next()
            out.append(record)
            if record.type == HistoryArchive.RecordType.end.rawValue { return out }
        }
    }

    private func expectRefusal(_ data: Data, _ what: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try readRecords(data)
            XCTFail("\(what) was ACCEPTED — it must be refused", file: file, line: line)
        } catch {
            XCTAssertTrue(error is HistoryArchive.ArchiveError,
                          "\(what) failed with an unexpected error: \(error)",
                          file: file, line: line)
        }
    }

    private func flipping(_ data: Data, at offset: Int) -> Data {
        var copy = data
        copy[copy.startIndex + offset] ^= 0x01
        return copy
    }

    // MARK: - 1. Header layout

    func testTheHeaderIsExactlyFortyEightBytesWithTheDocumentedLayout() throws {
        let header = HistoryArchive.Header(kdfIterations: 750_000,
                                           kdfSalt: Data(repeating: 0x11, count: 16),
                                           noncePrefix: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                                           chunkSize: HistoryArchive.defaultChunkSize)
        let d = header.encoded
        XCTAssertEqual(d.count, 48, "the header must be exactly 48 bytes")
        XCTAssertEqual(d.prefix(8), Data("CLIPHRD1".utf8), "magic at 0..8")
        XCTAssertEqual(HistoryArchive.readBE16(d, at: 8), 1, "version at 8, big-endian")
        XCTAssertEqual(d[10], HistoryArchive.kdfPBKDF2SHA256, "kdfID at 10")
        XCTAssertEqual(d[11], HistoryArchive.aeadAESGCM, "aeadID at 11")
        XCTAssertEqual(HistoryArchive.readBE32(d, at: 12), 750_000,
                       "kdfIterations at 12, big-endian")
        XCTAssertEqual(Data(d[16..<32]), Data(repeating: 0x11, count: 16), "salt at 16..32")
        XCTAssertEqual(Data(d[32..<36]), Data([0xDE, 0xAD, 0xBE, 0xEF]),
                       "noncePrefix at 32..36")
        XCTAssertEqual(HistoryArchive.readBE32(d, at: 36), HistoryArchive.defaultChunkSize,
                       "chunkSize at 36")
        XCTAssertEqual(HistoryArchive.readBE32(d, at: 40), 1040,
                       "summaryLen at 40 is the CONSTANT 1040 for every v1 file — a "
                       + "variable-length summary would leak its own length, which "
                       + "correlates with the machine name and the clip count")
        XCTAssertEqual(Data(d[44..<48]), Data(repeating: 0, count: 4),
                       "reserved is FOUR zero bytes at 44 — not eight; the header is 48 "
                       + "bytes and 44+8 would run past its end")
        // And it round-trips.
        XCTAssertEqual(try HistoryArchive.Header.decode(d), header)
    }

    // MARK: - 2/3. KDF parameters

    func testTheKDFParametersAreWhatTheDesignSays() throws {
        XCTAssertEqual(HistoryArchive.kdfSaltLength, 16)
        XCTAssertEqual(HistoryArchive.fileKeyLength, 32)
        XCTAssertEqual(HistoryArchive.kdfPBKDF2SHA256, 1)
        XCTAssertEqual(HistoryArchive.aeadAESGCM, 1)
        XCTAssertGreaterThanOrEqual(
            HistoryArchive.kdfRoundsFloor, 600_000,
            "the floor is the load-bearing number. It is compiled in precisely so a FILE "
            + "cannot lower it.")
        XCTAssertGreaterThanOrEqual(HistoryArchive.calibratedIterations,
                                    HistoryArchive.kdfRoundsFloor,
                                    "calibration may never go below the floor")
        XCTAssertLessThanOrEqual(HistoryArchive.calibratedIterations,
                                 HistoryArchive.kdfRoundsCeiling)
        XCTAssertEqual(HistoryArchive.calibratedIterations % 50_000, 0,
                       "rounded down to 50k, so the header does not fingerprint the Mac "
                       + "that made it any more finely than it must")
        let key = try XCTUnwrap(HistoryArchive.deriveKey(passphrase: Self.passphrase,
                                                          salt: Self.salt,
                                                          iterations: Self.iterations))
        XCTAssertEqual(key.bitCount, 256)
        // A different salt is a different key; the same inputs are the same key.
        let same = try XCTUnwrap(HistoryArchive.deriveKey(passphrase: Self.passphrase,
                                                          salt: Self.salt,
                                                          iterations: Self.iterations))
        XCTAssertEqual(key, same)
        let other = try XCTUnwrap(HistoryArchive.deriveKey(passphrase: Self.passphrase,
                                                           salt: Self.otherSalt,
                                                           iterations: Self.iterations))
        XCTAssertNotEqual(key, other)
        // NFC, not NFD: the same grapheme typed on two Macs must derive the SAME key.
        let composed = try XCTUnwrap(HistoryArchive.deriveKey(passphrase: "passphrase caf\u{00E9}",
                                                              salt: Self.salt,
                                                              iterations: Self.iterations))
        let decomposed = try XCTUnwrap(HistoryArchive.deriveKey(passphrase: "passphrase cafe\u{0301}",
                                                                salt: Self.salt,
                                                                iterations: Self.iterations))
        XCTAssertEqual(composed, decomposed,
                       "a composed and a decomposed é must derive the same key, or the "
                       + "file opens on the Mac that wrote it and nowhere else")
        // Spaces are part of the passphrase — no trimming.
        let padded = try XCTUnwrap(HistoryArchive.deriveKey(passphrase: " \(Self.passphrase) ",
                                                            salt: Self.salt,
                                                            iterations: Self.iterations))
        XCTAssertNotEqual(key, padded)
    }

    func testTheHKDFInfoStringIsPinned() throws {
        XCTAssertEqual(HistoryArchive.hkdfInfo, "cliphoard/export/v1/file-key")
        // …and that the constant is the one actually fed to HKDF. Comment lines stripped,
        // per `DocsLaunchClaimTests.testDatabaseSealsTheSourceAppName`: this file discusses
        // HKDF in prose, and matching a comment is the trap `ForgetOrderingTests` records.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Support/HistoryArchive.swift"),
            encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(source.contains("info: Data(hkdfInfo.utf8)"),
                      "the pinned info string is not the one HKDF is given")
        XCTAssertTrue(source.contains("CCKeyDerivationPBKDF"),
                      "PBKDF2 is the work factor. HKDF alone has none, and using it on a "
                      + "passphrase turns the file into an offline dictionary attack.")
    }

    // MARK: - 4/5. Header refusals, before any allocation

    func testAHeaderClaimingAnAbsurdIterationCountOrChunkSizeIsRefusedBeforeAnyAllocation() throws {
        func header(iterations: UInt32 = HistoryArchive.kdfRoundsFloor,
                    chunkSize: UInt32 = HistoryArchive.defaultChunkSize,
                    summaryLen: UInt32 = HistoryArchive.summaryLength,
                    reserved: UInt32 = 0) -> Data {
            var h = HistoryArchive.Header(kdfIterations: iterations,
                                          kdfSalt: Data(repeating: 1, count: 16),
                                          noncePrefix: Data([1, 2, 3, 4]),
                                          chunkSize: chunkSize)
            h.summaryLen = summaryLen
            h.reserved = reserved
            return h.encoded
        }
        // Only 48 bytes ever reach the decoder, so nothing can be allocated on the
        // strength of these numbers before they are checked.
        XCTAssertEqual(header().count, 48)

        assertThrows(.iterationsOutOfRange(1), header(iterations: 1),
                     "a parameter downgrade to one round")
        assertThrows(.iterationsOutOfRange(50_000_000), header(iterations: 50_000_000),
                     "an absurd round count")
        assertThrows(.chunkSizeOutOfRange(4_000_000_000), header(chunkSize: 4_000_000_000),
                     "a four-gigabyte block size")
        assertThrows(.chunkSizeOutOfRange(1024), header(chunkSize: 1024),
                     "a block size below the floor")
        assertThrows(.unexpectedSummaryLength(1_000_000_000),
                     header(summaryLen: 1_000_000_000), "a gigabyte summary block")
        assertThrows(.unexpectedSummaryLength(1039), header(summaryLen: 1039),
                     "any summary length other than the constant 1040")
        assertThrows(.reservedBytesNotZero, header(reserved: 1),
                     "a non-zero reserved field — no silent forward extension")
        var notMagic = header()
        notMagic[notMagic.startIndex] = 0x43 ^ 0xFF
        assertThrows(.notAnArchive, notMagic, "a file that is not an archive")
    }

    func testAFutureFormatVersionIsRefusedWithAMessageNamingTheVersion() throws {
        var h = HistoryArchive.Header(kdfIterations: HistoryArchive.kdfRoundsFloor,
                                      kdfSalt: Data(repeating: 1, count: 16),
                                      noncePrefix: Data([1, 2, 3, 4]),
                                      chunkSize: HistoryArchive.defaultChunkSize)
        h.version = 7
        assertThrows(.futureVersion(7), h.encoded, "a future format version")
        XCTAssertTrue(HistoryArchive.ArchiveError.futureVersion(7).message.contains("7"),
                      "the message must name the version, so the user knows what to update to")
        XCTAssertTrue(HistoryArchive.ArchiveError.futureVersion(7).message
                        .lowercased().contains("newer"),
                      "and must say the file is newer, not that it is broken")
    }

    private func assertThrows(_ expected: HistoryArchive.ArchiveError, _ header: Data,
                              _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try HistoryArchive.Header.decode(header)
            XCTFail("\(what) was ACCEPTED", file: file, line: line)
        } catch let error as HistoryArchive.ArchiveError {
            XCTAssertEqual(error, expected, "\(what) gave the wrong refusal",
                           file: file, line: line)
        } catch {
            XCTFail("\(what): unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - 6. Truncation

    func testTruncationIsRefusedAtEveryCutPoint() throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let name = HistoryArchive.sha256Hex(payload) + ".png"
        let archive = try build(payloads: [(name, payload)])
        let all = frames(in: archive)
        XCTAssertGreaterThanOrEqual(all.count, 3,
                                    "the fixture must span several chunks or the boundary "
                                    + "case below is not exercised")
        XCTAssertTrue(all.last!.isFinal, "the last frame must carry isFinal = 1")
        XCTAssertFalse(all.dropLast().contains { $0.isFinal })

        let header = HistoryArchive.headerLength
        let afterSummary = header + Int(HistoryArchive.summaryLength)
        let cuts: [(String, Int)] = [
            ("one byte", 1),
            ("the header only", header),
            ("the header and summary only", afterSummary),
            ("mid-chunk", all[0].offset + 5 + all[0].length / 2),
            // THE ONE THAT MATTERS. A reader that infers "last chunk" from the file length
            // accepts this as a complete, smaller history — and passes every other test in
            // this method by accident.
            ("exactly on a chunk boundary", all[0].offset + all[0].total),
            ("just before the final tag", archive.count - 1),
        ]
        for (what, cut) in cuts {
            expectRefusal(Data(archive.prefix(cut)), "a file truncated \(what)")
        }
        // …and the intact file is accepted, so the refusals above mean something.
        XCTAssertFalse(try readRecords(archive).isEmpty)
    }

    /// The chunk layer refuses EOF on its own, without help from the record layer.
    ///
    /// Found by a mutation check: making `ChunkReader` treat end-of-file as "that was the
    /// last chunk" — the length-inferring design §1.5 rejects — left
    /// `testTruncationIsRefusedAtEveryCutPoint` GREEN, because the record stream always ends
    /// with an `end` record inside the final chunk, so the RecordReader notices the shortfall
    /// a layer up. Defence in depth is the right answer, but a layer whose own rule nothing
    /// asserts is a layer that can be quietly deleted.
    func testTheChunkReaderRefusesEndOfFileWithoutTheFinalFlag() throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let archive = try build(payloads: [(HistoryArchive.sha256Hex(payload) + ".png", payload)])
        let all = frames(in: archive)
        XCTAssertGreaterThanOrEqual(all.count, 3)
        let cut = Data(archive.prefix(all[0].offset + all[0].total))

        let opened = try HistoryArchive.open(source: HistoryArchive.DataByteSource(cut),
                                             passphrase: Self.passphrase)
        let chunks = HistoryArchive.ChunkReader(source: opened.source, key: opened.key,
                                                header: opened.header)
        XCTAssertNotNil(try chunks.next(), "the surviving first chunk must still open")
        do {
            let extra = try chunks.next()
            XCTFail("the reader returned \(extra == nil ? "nil" : "a chunk") at end of file "
                    + "without ever having seen isFinal = 1. `nil` here means \"that was the "
                    + "whole archive\", which is precisely how a file cut on a chunk "
                    + "boundary becomes a valid, smaller history.")
        } catch let error as ArchiveErrorAlias {
            guard case .truncated = error else {
                return XCTFail("wrong refusal: \(error.message)")
            }
        }
    }

    // MARK: - 7/8/9. Tampering

    func testASingleFlippedByteIsRefused() throws {
        let archive = try build()
        let all = frames(in: archive)
        let sites: [(String, Int)] = [
            // The two HEADER sites prove the AAD binding, which a ciphertext-only test
            // cannot: the header is not encrypted, so nothing but its role as additional
            // authenticated data makes a flip there detectable.
            ("the KDF salt", 16),
            ("the iteration count", 15),
            ("the sealed summary", HistoryArchive.headerLength + 10),
            ("the first chunk's ciphertext", all[0].offset + 5 + 3),
            ("the last chunk's ciphertext", all.last!.offset + 5 + 3),
        ]
        for (what, offset) in sites {
            expectRefusal(flipping(archive, at: offset), "a flipped byte in \(what)")
        }
    }

    func testTrailingBytesAfterTheFinalChunkAreRefused() throws {
        let archive = try build()
        XCTAssertFalse(try readRecords(archive).isEmpty)
        expectRefusal(archive + Data([0x00]), "one appended byte")
        expectRefusal(archive + Data(repeating: 0x41, count: 4096), "4 KB of appended junk")
    }

    func testASplicedChunkFromAnotherExportIsRefused() throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 241) })
        let name = HistoryArchive.sha256Hex(payload) + ".png"
        let a = try build(payloads: [(name, payload)])
        let b = try build(salt: Self.otherSalt, noncePrefix: Self.otherNoncePrefix,
                          payloads: [(name, payload)])
        let framesA = frames(in: a)
        let framesB = frames(in: b)
        XCTAssertGreaterThanOrEqual(framesA.count, 3)
        XCTAssertEqual(framesA[1].total, framesB[1].total)

        // A chunk lifted from a DIFFERENT export: the header (a different salt and nonce
        // prefix) is in the AAD, so it cannot verify here.
        var spliced = a
        spliced.replaceSubrange(
            (spliced.startIndex + framesA[1].offset)
                ..< (spliced.startIndex + framesA[1].offset + framesA[1].total),
            with: b[(b.startIndex + framesB[1].offset)
                        ..< (b.startIndex + framesB[1].offset + framesB[1].total)])
        expectRefusal(spliced, "a chunk spliced in from another export")

        // And a chunk moved within ONE export.
        var reordered = a
        let first = Data(a[(a.startIndex + framesA[0].offset)
                            ..< (a.startIndex + framesA[0].offset + framesA[0].total)])
        let second = Data(a[(a.startIndex + framesA[1].offset)
                             ..< (a.startIndex + framesA[1].offset + framesA[1].total)])
        XCTAssertEqual(first.count, second.count)
        reordered.replaceSubrange(
            (reordered.startIndex + framesA[0].offset)
                ..< (reordered.startIndex + framesA[0].offset + first.count), with: second)
        reordered.replaceSubrange(
            (reordered.startIndex + framesA[1].offset)
                ..< (reordered.startIndex + framesA[1].offset + second.count), with: first)
        expectRefusal(reordered, "two chunks swapped inside one export")
    }

    /// The chunk index is bound TWICE — into the nonce and into the AAD — and a behavioural
    /// test cannot tell the two apart.
    ///
    /// This is here because a mutation check found it: deleting the index from the AAD left
    /// `testASplicedChunkFromAnotherExportIsRefused` GREEN, because the nonce alone already
    /// makes a moved chunk fail to open. The redundancy is deliberate (AAD binding is what
    /// would still catch a reorder if a future version ever derived the nonce differently),
    /// so it needs an assertion of its own or it is one careless tidy-up away from being
    /// gone with nothing turning red.
    func testTheChunkIndexIsBoundIntoBothTheNonceAndTheAAD() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Support/HistoryArchive.swift"),
            encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertEqual(
            source.components(separatedBy: "noncePrefix + HistoryArchive.be64(index)").count - 1, 2,
            "the writer and the reader must BOTH derive the nonce from the chunk index")
        XCTAssertEqual(
            source.components(separatedBy: "aad.append(HistoryArchive.be64(index))").count - 1, 2,
            "the writer and the reader must BOTH bind the chunk index into the AAD. A moved "
            + "chunk is caught by the nonce today, so removing this passes every behavioural "
            + "test — which is exactly why it is asserted here instead.")
        XCTAssertEqual(
            source.components(separatedBy: "aad.append(HistoryArchive.be32(length))").count - 1, 2,
            "the plaintext length must be bound into the AAD on both sides, or the length "
            + "prefix is unauthenticated")
    }

    // MARK: - 10. Content hashes

    func testAPayloadWhoseBytesDoNotHashToItsNameIsRefused() throws {
        let payload = ArchiveFixture.png(seed: 3)
        let honest = HistoryArchive.sha256Hex(payload) + ".png"
        let liar = HistoryArchive.sha256Hex(Data("something else".utf8)) + ".png"

        let good = try build(payloads: [(honest, payload)])
        let bad = try build(payloads: [(liar, payload)])
        let goodURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-good-\(UUID().uuidString).cliphoard")
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-bad-\(UUID().uuidString).cliphoard")
        try good.write(to: goodURL)
        try bad.write(to: badURL)
        defer {
            try? FileManager.default.removeItem(at: goodURL)
            try? FileManager.default.removeItem(at: badURL)
        }

        switch HistoryArchiveIO.verify(url: goodURL, passphrase: Self.passphrase) {
        case .success(let report): XCTAssertEqual(report.payloadCount, 1)
        case .failure(let error): XCTFail("an honest archive was refused: \(error.message)")
        }
        switch HistoryArchiveIO.verify(url: badURL, passphrase: Self.passphrase) {
        case .success: XCTFail("a payload whose bytes do not hash to its name was ACCEPTED")
        case .failure(let error):
            XCTAssertEqual(error, .payloadHashMismatch(liar),
                           "the name IS the integrity check — the file names are content "
                           + "hashes, so a swapped image must be caught by arithmetic and "
                           + "not by trust")
        }
    }

    // MARK: - Extra: the manifest must agree with the summary

    func testAManifestThatDisagreesWithTheSummaryIsRefused() throws {
        let archive = try build(manifestMutation: { $0.clipCount = 999 })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-liar-\(UUID().uuidString).cliphoard")
        try archive.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        switch HistoryArchiveIO.verify(url: url, passphrase: Self.passphrase) {
        case .success: XCTFail("a manifest that contradicts the sealed summary was ACCEPTED")
        case .failure(let error):
            guard case .manifestDisagreesWithSummary = error else {
                return XCTFail("wrong refusal: \(error.message)")
            }
        }
    }

    // MARK: - Extra: the passphrase floor and the generator

    func testTheGeneratedPassphraseIsLongUniformAndAlwaysAboveTheFloor() throws {
        var seen = Set<String>()
        for _ in 0..<32 {
            let generated = try XCTUnwrap(HistoryArchive.generatePassphrase())
            XCTAssertTrue(seen.insert(generated).inserted, "the generator repeated itself")
            XCTAssertEqual(generated.filter { $0 == "-" }.count, 4, "five groups")
            let letters = generated.filter { $0 != "-" }
            XCTAssertEqual(letters.count, 25, "25 base32 characters = 125 bits")
            XCTAssertTrue(letters.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".contains($0) },
                          "RFC 4648 base32 only — 32 divides 256, so masking to five bits "
                          + "is uniform with no rejection sampling and no modulo bias")
            XCTAssertGreaterThanOrEqual(generated.count,
                                        HistoryArchive.passphraseMinimumLength)
            XCTAssertEqual(HistoryArchive.passphraseStrength(generated), 4,
                           "a generated passphrase must read as strong")
        }
        XCTAssertEqual(HistoryArchive.passphraseMinimumLength, 12, "the hard floor")
        XCTAssertEqual(HistoryArchive.passphraseStrength("short"), 0)
        XCTAssertEqual(HistoryArchive.passphraseStrength("elevenchars"), 0,
                       "eleven characters is below the floor")
        XCTAssertGreaterThan(HistoryArchive.passphraseStrength("twelvechars!"), 0)
    }
}
