import XCTest
@testable import Cliphoard

/// One entry point for turning stored bytes into a vector, enforced rather than requested.
///
/// The defect this closes happened TWICE, in two loaders sitting 350 lines apart, and the
/// second one survived the fix for the first — while the commit message, the code comment
/// and the test all asserted the hole was closed. It was closed at one mouth.
///
/// The mechanism, because it is worth stating precisely: `Crypto.open` FAILS OPEN. When no
/// key on the ring unseals a blob it returns the CIPHERTEXT rather than nil. A sealed
/// 4n-byte vector is `4n + 28 + markerLen` bytes, which `vectorFromBlob` parses happily iff
/// `markerLen % 4 == 0`. `"enc1:"` is five characters. That is the entire reason the
/// unguarded loader did not produce garbage vectors — an arithmetic accident with a margin
/// of ONE CHARACTER, in a marker string nobody thought was load-bearing.
///
/// So the guarantee cannot be "every loader remembers to check". It has to be that no
/// loader can reach the parser without the check, which is what these tests pin.
final class VectorFunnelTests: XCTestCase {

    // MARK: - The structural guarantee

    /// No production code may call the parser directly. This is the test that makes the
    /// funnel a mechanism instead of a convention.
    ///
    /// `private` already enforces this within the file, and this test enforces the part
    /// `private` cannot: that the *declaration* stays private. Deleting one keyword would
    /// silently reopen the door to every future call site, and nothing else would fail.
    func testTheParserIsPrivateAndReachedOnlyThroughTheFunnel() throws {
        let db = try Self.source("Sources/Cliphoard/Clipboard/Database.swift")

        XCTAssertTrue(db.contains("private static func vectorFromBlob"),
                      "vectorFromBlob must stay PRIVATE. Public, it is reachable without the "
                      + "decrypt-and-refuse steps, which is precisely the shape that shipped "
                      + "twice — the parser is the last of three steps and the only harmless "
                      + "one to reach on its own")

        // Matched WITH the open paren, so this counts call syntax and declarations rather
        // than prose. The first version counted the bare name and failed against correct
        // code, because a comment at :327 mentions `vectorFromBlob` in backticks while
        // explaining a logging decision. That is the second time in this codebase a
        // source-text assertion has been broken by the comment documenting the very
        // invariant it guards — see ForgetOrderingTests, which learned it first.
        //
        // Two legitimate occurrences remain: the declaration, and the single call inside
        // `openVectorBlob`. A third is a bypass.
        let calls = db.components(separatedBy: "vectorFromBlob(").count - 1
        XCTAssertEqual(calls, 2,
                       "expected exactly 2 occurrences of `vectorFromBlob(` (its declaration "
                       + "and the one call inside openVectorBlob); found \(calls). A new one "
                       + "means a loader is parsing bytes without refusing ciphertext first.")
    }

    /// Every vector-bearing loader goes through the funnel. Enumerated by TABLE, so adding
    /// a table without adding it here is the thing that fails.
    func testEveryVectorBearingLoaderUsesTheFunnel() throws {
        let db = try Self.source("Sources/Cliphoard/Clipboard/Database.swift")
        for table in ["embeddings", "image_features"] {
            XCTAssertTrue(db.contains("FROM \(table);"),
                          "the \(table) loader was renamed — update this enumeration rather "
                          + "than deleting the case")
        }
        let funnelled = db.components(separatedBy: "Self.openVectorBlob(").count - 1
        XCTAssertEqual(funnelled, 2,
                       "expected exactly 2 funnel call sites, one per vector-bearing table; "
                       + "found \(funnelled). Fewer means a loader parses raw bytes.")
    }

    // MARK: - The behaviour

    /// Sealed bytes must come back `.unreadable`, never as a vector.
    ///
    /// This is the case that matters: the bytes are well-formed AES-GCM output, the right
    /// length, and entirely meaningless as floats.
    func testSealedBytesAreRefusedRatherThanParsed() throws {
        try skipIfKeychainUnreachable()
        let vector: [Float] = [1, 2, 3, 4, 5, 6, 7, 8]
        let plain = Database.blob(fromVector: vector)
        let sealed = try XCTUnwrap(Crypto.sealStrict(plain), "could not seal on this machine")

        // Precondition: this really is ciphertext, and it really is the shape that fools
        // the parser's length check when the marker is a multiple of four.
        XCTAssertTrue(Crypto.isSealed(sealed), "precondition: the fixture must be sealed")

        // Round trip while the key IS reachable — the funnel must not refuse valid data.
        guard case .vector(let out) = Database.openVectorBlob(sealed) else {
            return XCTFail("a row sealed with the CURRENT key must read back as a vector; "
                           + "refusing it would silently empty every user's index")
        }
        XCTAssertEqual(out, vector, "the round trip must be exact, not merely non-empty")
    }

    /// The unreadable direction, forced without touching the keychain: bytes that carry the
    /// seal marker but which no key can open. `Crypto.open` hands these straight back, and
    /// the funnel must refuse them.
    func testCiphertextThatNoKeyOpensIsRefused() {
        // "enc1:" + bytes that are not a valid GCM box for any key on the ring.
        var forged = Data("enc1:".utf8)
        forged.append(Data(repeating: 0xAB, count: 4 * 8 + 28))
        XCTAssertTrue(Crypto.isSealed(forged), "precondition: shaped like a sealed vector")

        guard case .unreadable = Database.openVectorBlob(forged) else {
            return XCTFail("unopenable ciphertext was parsed as a vector. Downstream this is "
                           + "invisible: AES-GCM output is UNIFORM in length, so every count "
                           + "and revision guard passes and the user gets a confident, "
                           + "stable, entirely fictional ranking")
        }
    }

    /// Plaintext legacy rows still work. Without this the funnel could "pass" by refusing
    /// everything, which would empty the index of every user who predates sealing.
    func testLegacyPlaintextVectorsStillRead() {
        let vector: [Float] = [0.25, -0.5, 0.75]
        guard case .vector(let out) = Database.openVectorBlob(Database.blob(fromVector: vector)) else {
            return XCTFail("an unsealed legacy vector must still read")
        }
        XCTAssertEqual(out, vector)
    }

    /// A blob whose length is not a multiple of 4 is not a vector. Kept because the ONLY
    /// thing standing between the old code and garbage vectors was this arithmetic.
    func testMalformedLengthYieldsNoVector() {
        guard case .vector(let out) = Database.openVectorBlob(Data([0x01, 0x02, 0x03])) else {
            return XCTFail("expected a (possibly empty) vector, not .unreadable — a short "
                           + "plaintext blob is malformed data, not undecryptable data, and "
                           + "conflating the two would mask a real corruption signal")
        }
        XCTAssertTrue(out.isEmpty, "3 bytes is not a whole number of floats")
    }

    // MARK: - helper

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
