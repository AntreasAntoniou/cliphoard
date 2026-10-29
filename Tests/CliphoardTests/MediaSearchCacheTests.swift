import XCTest
import CryptoKit
@testable import Cliphoard

final class MediaSearchCacheTests: XCTestCase {
    private var identity: MediaSearchCache.Identity {
        .init(contentSHA256: String(repeating: "a", count: 64), modelRevision: "public-model-v1",
              preprocessingRevision: "jpeg-wav-v1", samplingRevision: "balanced-v1")
    }
    private func codec() -> MediaSearchCache {
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        return MediaSearchCache(seal: { bytes in
            Data("enc1:".utf8) + (try! AES.GCM.seal(bytes, using: key).combined!)
        }, open: { bytes in
            try? AES.GCM.open(AES.GCM.SealedBox(combined: bytes.dropFirst(5)), using: key)
        })
    }
    func testEncryptedRoundTripAndWrongIdentityRefusal() throws {
        let cache = codec()
        let record = MediaSearchCache.Record(identity: identity, duration: 10,
            vectors: [.init(modality: .video, start: 1, end: 2, vector: [0.6, 0.8])])
        let sealed = try cache.seal(record)
        XCTAssertTrue(sealed.starts(with: Data("enc1:".utf8)))
        XCTAssertNil(String(data: sealed, encoding: .utf8))
        XCTAssertEqual(try cache.open(sealed, expected: identity), record)
        var other = identity; other.modelRevision = "another-model"
        XCTAssertThrowsError(try cache.open(sealed, expected: other))
    }
    func testTamperFailureAndSealRefusalNeverReturnPlaintext() throws {
        let record = MediaSearchCache.Record(identity: identity, duration: 10,
            vectors: [.init(modality: .audio, start: 1, end: 2, vector: [1, 0])])
        let cache = codec(); var bytes = try cache.seal(record); bytes[bytes.count - 1] ^= 1
        XCTAssertThrowsError(try cache.open(bytes, expected: identity))
        XCTAssertThrowsError(try MediaSearchCache(seal: { _ in nil }, open: { _ in nil }).seal(record))
        XCTAssertThrowsError(try MediaSearchCache(seal: { $0 }, open: { $0 }).seal(record))
    }
    func testTemporalDimensionAndCountLimits() throws {
        let cache = codec()
        for vectors in [
            [MediaSearchCache.TimedVector(modality: .audio, start: -1, end: 2, vector: [1])],
            [.init(modality: .audio, start: 1, end: 11, vector: [1])],
            [.init(modality: .audio, start: 1, end: 2, vector: [0, 0])],
            [.init(modality: .audio, start: 1, end: 2, vector: [1]), .init(modality: .audio, start: 2, end: 3, vector: [1, 0])],
            Array(repeating: .init(modality: .audio, start: 1, end: 2, vector: [1]), count: 121)
        ] { XCTAssertThrowsError(try cache.seal(.init(identity: identity, duration: 10, vectors: vectors))) }
    }
    func testCorruptPlaintextAndInvalidVectorsRefused() throws {
        let cache = codec()
        XCTAssertThrowsError(try cache.open(Data("plaintext".utf8), expected: identity))
        let record = MediaSearchCache.Record(identity: identity, duration: 10,
            vectors: [.init(modality: .audio, start: 1, end: 2, vector: [.nan])])
        XCTAssertThrowsError(try cache.seal(record))
    }
}
