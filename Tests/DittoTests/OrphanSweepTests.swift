import XCTest
@testable import Ditto

/// BL-18: on launch the store removes stray "*.png" payloads on disk that no
/// live item references, while leaving referenced payloads untouched.
@MainActor
final class OrphanSweepTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoOrphanTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testInitRemovesUnreferencedPNGAndKeepsReferenced() throws {
        let referencedName = "kept.png"
        let strayName = "stray.png"
        let referencedURL = tempDir.appendingPathComponent(referencedName)
        let strayURL = tempDir.appendingPathComponent(strayName)
        let png = Data([0x89, 0x50, 0x4E, 0x47]) // "\x89PNG" magic, contents irrelevant
        try png.write(to: referencedURL)
        try png.write(to: strayURL)

        // Seed a legacy history.json holding a single image clip that references
        // kept.png. With an empty database this is migrated in on init, so the
        // referenced file becomes a live payload.
        let json = """
        [{"id":"\(UUID().uuidString)","kind":"image","text":"Image",
          "payloadFile":"\(referencedName)",
          "createdAt":1,"lastUsedAt":1,"pinned":false,"useCount":0}]
        """.data(using: .utf8)!
        try json.write(to: tempDir.appendingPathComponent("history.json"))

        let store = ClipStore(directory: tempDir)
        XCTAssertEqual(store.items.count, 1, "referenced clip should have migrated in")
        XCTAssertEqual(store.items.first?.payloadFile, referencedName)

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: strayURL.path),
            "unreferenced PNG should be swept on init")
        XCTAssertTrue(fm.fileExists(atPath: referencedURL.path),
            "referenced PNG must remain")
    }
}
