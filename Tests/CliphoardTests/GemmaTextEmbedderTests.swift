import XCTest
@testable import Cliphoard

final class GemmaTextEmbedderTests: XCTestCase {
    actor Backend {
        var calls: [(String, Bool)] = []
        var running = 0
        var maximumRunning = 0
        var failNext = false
        func embed(_ text: String, query: Bool) async throws -> [Float] {
            calls.append((text, query)); running += 1
            maximumRunning = max(maximumRunning, running)
            defer { running -= 1 }
            try await Task.sleep(nanoseconds: 20_000_000)
            if failNext { failNext = false; throw Failure.failed }
            return [query ? 1 : 0, query ? 0 : 1] + Array(repeating: 0, count: 766)
        }
        func setFailure() { failNext = true }
        enum Failure: Error { case failed }
    }
    func testColdRequestIsNonblockingThenWakesAndReusesCorrectRole() async {
        let backend = Backend()
        let ready = expectation(description: "document ready")
        let embedder = GemmaTextEmbedder(compute: { try await backend.embed($0, query: $1) }, changed: { ready.fulfill() })
        XCTAssertEqual(embedder.embed("hello"), [])
        let doc = await embedder.vector("hello")
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(doc.count, 768)
        XCTAssertEqual(embedder.embed("hello"), doc)
        let count = await backend.calls.count
        XCTAssertEqual(count, 1)
    }
    func testQueryAndDocumentAreSeparateAndInferenceSerializes() async {
        let backend = Backend()
        let embedder = GemmaTextEmbedder(compute: { try await backend.embed($0, query: $1) }, changed: {})
        async let a = embedder.vector("same", query: true)
        async let b = embedder.vector("same", query: false)
        let (query, doc) = await (a, b)
        XCTAssertNotEqual(query, doc)
        let maximum = await backend.maximumRunning
        let count = await backend.calls.count
        XCTAssertEqual(maximum, 1); XCTAssertEqual(count, 2)
    }
    func testFailedVectorNeverCachedAndCanRetry() async {
        let backend = Backend(); await backend.setFailure()
        let embedder = GemmaTextEmbedder(compute: { try await backend.embed($0, query: $1) }, changed: {})
        let failed = await embedder.vector("retry")
        XCTAssertTrue(failed.isEmpty); XCTAssertTrue(embedder.cachedDocument("retry").isEmpty)
        let retried = await embedder.vector("retry")
        XCTAssertEqual(retried.count, 768)
    }
    func testCancelledModelDoesNotPublishOrRepopulateCache() async {
        let backend = Backend()
        let embedder = GemmaTextEmbedder(compute: { try await backend.embed($0, query: $1) }, changed: { XCTFail("stopped model published") })
        _ = embedder.embed("queued")
        embedder.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(embedder.cachedDocument("queued").isEmpty)
        let value = await embedder.vector("queued")
        XCTAssertTrue(value.isEmpty)
    }
    func testAdmissionDenialDoesNotCompute() async {
        let backend = Backend()
        let embedder = GemmaTextEmbedder(compute: { try await backend.embed($0, query: $1) }, changed: {})
        let value = await embedder.vector("sensitive", admit: { false })
        XCTAssertTrue(value.isEmpty)
        let count = await backend.calls.count
        XCTAssertEqual(count, 0)
    }
    func testAwaitedDocumentsDoNotTriggerPerClipUIRefresh() async {
        let embedder = GemmaTextEmbedder(compute: { _, _ in [1] + Array(repeating: 0, count: 767) },
            changed: { XCTFail("index loop owns document progress") })
        for n in 0..<30 { _ = await embedder.vector("doc \(n)") }
    }
    actor Admission {
        var allowed = true
        func set(_ value: Bool) { allowed = value }
        func check() -> Bool { allowed }
    }
    func testNewGenerationRetriesTaskOwnedByRejectedOldGeneration() async {
        let gate = Admission()
        let backend = Backend()
        let embedder = GemmaTextEmbedder(compute: { try await backend.embed($0, query: $1) }, changed: {})
        _ = embedder.embed("blocker")
        let old = Task { await embedder.vector("same", admit: { await gate.check() }) }
        try? await Task.sleep(nanoseconds: 5_000_000)
        await gate.set(false)
        let current = await embedder.vector("same")
        let stale = await old.value
        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(current.count, 768)
        let count = await backend.calls.filter { $0.0 == "same" }.count
        XCTAssertEqual(count, 1)
    }
    func testPrefixPreservesUTF8AndIdentityNamesStrategy() {
        let value = GemmaTextEmbedder.boundedText(String(repeating: "🙂", count: 300))
        XCTAssertEqual(value.utf8.count, 1024)
        XCTAssertEqual(value.count, 256)
        XCTAssertEqual(DeepSearchLevel.gemma2.dimension, 768)
        let embedder = GemmaTextEmbedder(compute: { _,_ in [] }, changed: {})
        XCTAssertTrue(embedder.signature.contains("text-prefix1024-v1"))
    }
    @MainActor
    func testColdTagVectorsAreRecomputedAfterPreparation() async {
        let embedder = GemmaTextEmbedder(compute: { _, _ in [1] + Array(repeating: 0, count: 767) }, changed: {})
        let names = ["science", "music"]
        let first = TagSpace.vectors(using: embedder, names: names, fingerprint: "gemma-test-v1")
        XCTAssertTrue(first.contains(where: \.isEmpty))
        for name in names { _ = await embedder.vector(name) }
        let warm = TagSpace.vectors(using: embedder, names: names, fingerprint: "gemma-test-v1")
        XCTAssertTrue(warm.allSatisfy { $0.count == 768 })
        XCTAssertEqual(SemanticRanker.cosine(warm[0], warm[1]), 1, accuracy: 0.001)
    }
}

extension GemmaTextEmbedderTests {
    @MainActor
    func testSlowSynchronousBackendDoesNotOccupyMainActor() async {
        let started = expectation(description: "background inference started")
        let resumed = expectation(description: "main actor tick")
        let gate = DispatchSemaphore(value: 0)
        let embedder = GemmaTextEmbedder(dimension: 3, signature: "slow-fake", truncate: false,
            compute: { _, _ in
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                guard gate.wait(timeout: .now() + 2) == .success else { return [] }
                return [1, 0, 0]
            }, changed: {})
        let result = Task { await embedder.vector("long synchronous operation") }
        await fulfillment(of: [started], timeout: 1)
        Task { @MainActor in resumed.fulfill(); gate.signal() }
        await fulfillment(of: [resumed], timeout: 1)
        let vector = await result.value
        XCTAssertEqual(vector, [1, 0, 0])
        embedder.cancel()
    }

    func testGenericBackendRetainsItsFullInputAndIdentity() async {
        actor Capture {
            var text = ""
            func run(_ value: String) -> [Float] { text = value; return [1, 0, 0] }
        }
        let capture = Capture()
        let embedder = GemmaTextEmbedder(dimension: 3, signature: "existing-model-v1",
            relevanceFloor: 0.35, truncate: false,
            compute: { text, _ in await capture.run(text) }, changed: {})
        let text = String(repeating: "word ", count: 600)
        let vector = await embedder.vector(text)
        let captured = await capture.text
        XCTAssertEqual(captured, text)
        XCTAssertEqual(vector.count, 3)
        XCTAssertEqual(embedder.signature, "existing-model-v1")
        XCTAssertEqual(embedder.relevanceFloor, 0.35)
        embedder.cancel()
    }
}
