import XCTest
@testable import Cliphoard

/// Exercise the real file operations without needing a clipboard store or a Keychain.
/// The live Store test additionally supplies an NSSavePanel's selected-file grant.
@MainActor
final class HistoryArchiveExportFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CliphoardExportFile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testNewArchiveIsStagedOutsideTheSelectedDirectoryAndInstalledComplete() throws {
        let destination = root.appendingPathComponent("history.cliphoard")
        let sibling = root.appendingPathComponent("history.cliphoard-partial")
        let unrelated = Data("another document, not ours to remove".utf8)
        try unrelated.write(to: sibling)
        let bytes = Data(repeating: 0xA5, count: 8192)

        let file = try HistoryArchiveIO.ExportFile(destination: destination)
        defer { file.cleanup() }
        XCTAssertNotEqual(file.partial.deletingLastPathComponent(), root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try file.handle.write(contentsOf: bytes.prefix(4096))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a partial export must never appear under the selected archive name")
        try file.handle.write(contentsOf: bytes.suffix(4096))
        try file.finish()

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try Data(contentsOf: sibling), unrelated)
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)
        file.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.partialDirectory.path))
    }

    func testReplacementKeepsOldArchiveUntilCompleteAndUsesPrivatePermissions() throws {
        let destination = root.appendingPathComponent("history.cliphoard")
        let old = Data("previous complete encrypted backup".utf8)
        try old.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: destination.path)
        let file = try HistoryArchiveIO.ExportFile(destination: destination)
        defer { file.cleanup() }
        let replacement = Data(repeating: 0xF1, count: 8192)
        try file.handle.write(contentsOf: replacement)
        XCTAssertEqual(try Data(contentsOf: destination), old)
        try file.finish()
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600,
                       "replacement must not inherit weaker permissions from the old file")
    }

    func testAbortedWriteRemovesOnlyItsStagingDirectoryAndKeepsOldArchive() throws {
        let destination = root.appendingPathComponent("history.cliphoard")
        let old = Data("previous complete encrypted backup".utf8)
        try old.write(to: destination)
        let file = try HistoryArchiveIO.ExportFile(destination: destination)
        try file.handle.write(contentsOf: Data(repeating: 0xAB, count: 4096))
        file.cleanup() // An encryption or source-read failure never calls finish().
        XCTAssertEqual(try Data(contentsOf: destination), old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.partialDirectory.path))
    }

    func testFailedReplacementPreservesPreviousArchiveAndCleansTemporaryBytes() throws {
        let destination = root.appendingPathComponent("history.cliphoard")
        let old = Data("previous complete encrypted backup".utf8)
        try old.write(to: destination)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: destination.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: destination.path)
        }
        let file = try HistoryArchiveIO.ExportFile(destination: destination)
        try file.handle.write(contentsOf: Data(repeating: 0xBC, count: 4096))
        XCTAssertThrowsError(try file.finish())
        XCTAssertEqual(try Data(contentsOf: destination), old)
        file.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.partialDirectory.path))
    }

    func testWrappedReplacementFailurePreservesRelocatedOriginalInsideStaging() throws {
        let destination = root.appendingPathComponent("history.cliphoard")
        let old = Data("previous complete encrypted backup".utf8)
        try old.write(to: destination)
        let file = try HistoryArchiveIO.ExportFile(destination: destination)
        defer { try? FileManager.default.removeItem(at: file.partialDirectory) }
        try file.handle.write(contentsOf: Data(repeating: 0xBC, count: 4096))
        let recovered = file.partialDirectory.appendingPathComponent("previous-archive")
        // macOS exposes both spellings. The cleanup guard must compare resolved URLs.
        let aliasPath = recovered.path.hasPrefix("/private/var/")
            ? String(recovered.path.dropFirst("/private".count))
            : recovered.path.hasPrefix("/var/") ? "/private" + recovered.path : recovered.path
        let reported = URL(fileURLWithPath: aliasPath)
        XCTAssertThrowsError(try file.finish { original, _ in
            try FileManager.default.moveItem(at: original, to: recovered)
            let underlying = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                     userInfo: ["NSFileOriginalItemLocationKey": reported])
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSUnderlyingErrorKey: underlying])
        }) { error in
            XCTAssertEqual(error as? HistoryArchive.ArchiveError, .exportRecoveryRequired(reported))
            let message = (error as? HistoryArchive.ArchiveError)?.message ?? ""
            XCTAssertTrue(message.contains(reported.path))
            XCTAssertFalse(message.contains("Nothing was left behind"))
        }
        file.cleanup()
        XCTAssertEqual(try Data(contentsOf: recovered), old,
                       "deferred cleanup must never delete a relocated original backup")
    }

    func testRecoveryOutsideStagingDoesNotPreventCleanupOfOurEncryptedPartial() throws {
        let destination = root.appendingPathComponent("history.cliphoard")
        let old = Data("previous complete encrypted backup".utf8)
        try old.write(to: destination)
        let file = try HistoryArchiveIO.ExportFile(destination: destination)
        let recovered = root.appendingPathComponent("recovered.cliphoard")
        try file.handle.write(contentsOf: Data(repeating: 0xCD, count: 4096))
        XCTAssertThrowsError(try file.finish { original, _ in
            try FileManager.default.moveItem(at: original, to: recovered)
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: ["NSFileOriginalItemLocationKey": recovered])
        }) { error in
            XCTAssertEqual(error as? HistoryArchive.ArchiveError, .exportRecoveryRequired(recovered))
        }
        file.cleanup()
        XCTAssertEqual(try Data(contentsOf: recovered), old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.partialDirectory.path))
    }
}
