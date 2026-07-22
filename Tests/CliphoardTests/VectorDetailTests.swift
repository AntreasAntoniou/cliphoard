import XCTest
@testable import Cliphoard

/// The head-selection setting: mapping to CoreML output/dimension, the default,
/// and the per-head calibrated relevance floors.
final class VectorDetailTests: XCTestCase {
    func testDefaultIsFull1024() {
        UserDefaults.standard.removeObject(forKey: "vectorDetail")
        XCTAssertEqual(DeepSearch.detail, .full1024, "1024-d head is the default")
    }

    func testHeadMapping() {
        XCTAssertEqual(VectorDetail.full1024.dimension, 1024)
        XCTAssertEqual(VectorDetail.full1024.outputName, "embedding_large")
        XCTAssertEqual(VectorDetail.compact384.dimension, 384)
        XCTAssertEqual(VectorDetail.compact384.outputName, "embedding")
    }

    func testOgmaTiersFollowTheSelectedDetail() {
        let saved = UserDefaults.standard.string(forKey: "vectorDetail")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "vectorDetail") }
            else { UserDefaults.standard.removeObject(forKey: "vectorDetail") }
        }
        DeepSearch.detail = .full1024
        XCTAssertEqual(DeepSearchLevel.normal.dimension, 1024)
        XCTAssertEqual(DeepSearchLevel.low.dimension, 1024)
        DeepSearch.detail = .compact384
        XCTAssertEqual(DeepSearchLevel.normal.dimension, 384)
        XCTAssertEqual(DeepSearchLevel.low.dimension, 384)
    }

    func testFloorsMatchTheHeadsCalibration() {
        // From tools/validate_models.py: noise p95 ≈ 0.40 (1024) / 0.56 (384) —
        // each floor must sit above its own head's noise, and the spaces differ.
        XCTAssertGreaterThan(VectorDetail.compact384.relevanceFloor,
                             VectorDetail.full1024.relevanceFloor)
        XCTAssertEqual(VectorDetail.full1024.relevanceFloor, 0.40, accuracy: 0.001)
    }

    func testSignatureEncodesTheHeadDimension() {
        // Vectors from different heads must never be compared: the signature
        // carries the dimension, so per-model caches stay disjoint.
        XCTAssertNotEqual("open-ogma-small-\(VectorDetail.full1024.dimension)-v1",
                          "open-ogma-small-\(VectorDetail.compact384.dimension)-v1")
    }
}
