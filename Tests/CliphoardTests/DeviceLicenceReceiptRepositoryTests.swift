#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import XCTest
import Foundation
import Darwin
@testable import Cliphoard

func receiptTestDirectory() throws -> URL {
    guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
        throw DeviceLicenceReceiptStorageFailure.invalidPath
    }
    defer { free(resolved) }
    let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        .appendingPathComponent("cliphoard-receipt-test-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    return root
}

final class ReceiptFaultIO: DeviceLicenceReceiptFileIO, @unchecked Sendable {
    enum Fault { case none, read, partialWrite, fileSync, directorySync, renameAfter, readback }
    let native = DeviceLicenceReceiptPOSIXIO()
    let fault: Fault
    private let lock = NSLock()
    private var renamed = false
    init(_ fault: Fault) { self.fault = fault }
    func read(_ fd: Int32, maximum: Int) throws -> Data {
        lock.lock(); let afterRename = renamed; lock.unlock()
        if fault == .read || (fault == .readback && afterRename) { throw DeviceLicenceReceiptStorageFailure.io }
        return try native.read(fd, maximum: maximum)
    }
    func write(_ bytes: Data, to fd: Int32) throws {
        if fault == .partialWrite {
            try native.write(Data(bytes.prefix(3)), to: fd); throw DeviceLicenceReceiptStorageFailure.io
        }
        try native.write(bytes, to: fd)
    }
    func synchronize(_ fd: Int32, full: Bool) throws {
        if (full && fault == .fileSync) || (!full && fault == .directorySync) { throw DeviceLicenceReceiptStorageFailure.io }
        try native.synchronize(fd, full: full)
    }
    func rename(in directory: Int32, from: String, to: String) throws {
        try native.rename(in: directory, from: from, to: to)
        lock.lock(); renamed = true; lock.unlock()
        if fault == .renameAfter { throw DeviceLicenceReceiptStorageFailure.io }
    }
}

final class DeviceLicenceReceiptRepositoryTests: XCTestCase {
    func testExactEnvelopeSurvivesRepositoryRecreation() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("approved.receipt")
        let first = try DeviceLicenceReceiptRepository(fileURL: url)
        let empty = try await first.read(); XCTAssertNil(empty.envelope)
        let envelope = "CLIPD1.cGF5bG9hZA.c2ln"
        let saved = try await first.replace(envelope, expectedRevision: empty.revision, permit: .init())
        let restored = try await DeviceLicenceReceiptRepository(fileURL: url).read()
        XCTAssertEqual(restored, saved); XCTAssertEqual(restored.envelope, envelope)
    }

    func testIndependentRepositoryCannotOverwriteAChangedRevision() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("approved.receipt")
        let first = try DeviceLicenceReceiptRepository(fileURL: url)
        let second = try DeviceLicenceReceiptRepository(fileURL: url)
        let stale = try await second.read()
        let saved = try await first.replace("CLIPD1.YQ.Yg", expectedRevision: nil, permit: .init())
        do {
            _ = try await second.replace("CLIPD1.Yw.ZA", expectedRevision: stale.revision, permit: .init())
            XCTFail("stale writer replaced the durable winner")
        } catch { XCTAssertEqual(error as? DeviceLicenceReceiptStorageFailure, .conflict) }
        let current = try await first.read(); XCTAssertEqual(current, saved)
    }

    func testMalformedPriorRecordIsPreserved() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("approved.receipt")
        let corrupt = Data("unknown-format\n".utf8)
        FileManager.default.createFile(atPath: url.path, contents: corrupt, attributes: [.posixPermissions: 0o600])
        let repository = try DeviceLicenceReceiptRepository(fileURL: url)
        do { _ = try await repository.read(); XCTFail("corrupt record accepted") }
        catch { XCTAssertEqual(error as? DeviceLicenceReceiptStorageFailure, .corrupt) }
        do { _ = try await repository.replace("CLIPD1.YQ.Yg", expectedRevision: nil, permit: .init()); XCTFail() }
        catch { XCTAssertEqual(error as? DeviceLicenceReceiptStorageFailure, .corrupt) }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testReadAndPreCommitWriteFaultsDoNotChangeLastGoodBytes() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("approved.receipt")
        let repository = try DeviceLicenceReceiptRepository(fileURL: url)
        let prior = try await repository.replace("CLIPD1.YQ.Yg", expectedRevision: nil, permit: .init())
        let bytes = try Data(contentsOf: url)
        for fault in [ReceiptFaultIO.Fault.read, .partialWrite, .fileSync] {
            let failing = try DeviceLicenceReceiptRepository(fileURL: url, io: ReceiptFaultIO(fault))
            do { _ = try await failing.replace("CLIPD1.Yw.ZA", expectedRevision: prior.revision, permit: .init()); XCTFail() }
            catch { XCTAssertEqual(error as? DeviceLicenceReceiptStorageFailure, .io) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".tmp") })
    }

    func testPostRenameFaultIsUncertainAndNeverRollsBack() async throws {
        for fault in [ReceiptFaultIO.Fault.renameAfter, .directorySync, .readback] {
            let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("approved.receipt")
            let repository = try DeviceLicenceReceiptRepository(fileURL: url)
            let prior = try await repository.replace("CLIPD1.YQ.Yg", expectedRevision: nil, permit: .init())
            let failing = try DeviceLicenceReceiptRepository(fileURL: url, io: ReceiptFaultIO(fault))
            do { _ = try await failing.replace("CLIPD1.Yw.ZA", expectedRevision: prior.revision, permit: .init()); XCTFail() }
            catch { XCTAssertEqual(error as? DeviceLicenceReceiptStorageFailure, .commitUncertain) }
            let durable = try await repository.read()
            XCTAssertEqual(durable.envelope, "CLIPD1.Yw.ZA"); XCTAssertNotEqual(durable.revision, prior.revision)
        }
    }

    func testCancelledPermitCannotReplaceApprovedBytes() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("approved.receipt"), permit = DeviceLicenceReceiptPermit()
        let repository = try DeviceLicenceReceiptRepository(fileURL: url)
        let prior = try await repository.replace("CLIPD1.YQ.Yg", expectedRevision: nil, permit: .init())
        let bytes = try Data(contentsOf: url); permit.cancel()
        do { _ = try await repository.replace("CLIPD1.Yw.ZA", expectedRevision: prior.revision, permit: permit); XCTFail() }
        catch { XCTAssertEqual(error as? DeviceLicenceReceiptStorageFailure, .cancelled) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testSeparateDescriptorLockBlocksRepositoryWithoutWaiting() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try DeviceLicenceReceiptRepository(fileURL: root.appendingPathComponent("approved.receipt"))
        _ = try await repository.read()
        let fd = open(root.appendingPathComponent(".approved.receipt.lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0); defer { _ = flock(fd, LOCK_UN) }
        do { _ = try await repository.read(); XCTFail("advisory lock ignored") }
        catch { XCTAssertEqual(error as? DeviceLicenceReceiptStorageFailure, .busy) }
    }

    func testSymlinksHardlinksAndNonPrivateDirectoryAreRejected() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        FileManager.default.createFile(atPath: target.path, contents: Data("untouched".utf8), attributes: [.posixPermissions: 0o600])
        let symlink = root.appendingPathComponent("symlink.receipt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let hardlink = root.appendingPathComponent("hardlink.receipt")
        try FileManager.default.linkItem(at: target, to: hardlink)
        let directoryLink = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        for url in [symlink, hardlink, directoryLink.appendingPathComponent("missing.receipt")] {
            let repository = try DeviceLicenceReceiptRepository(fileURL: url)
            do { _ = try await repository.read(); XCTFail("unsafe path accepted") }
            catch { XCTAssertEqual(error as? DeviceLicenceReceiptStorageFailure, .insecurePath) }
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
        XCTAssertEqual(chmod(root.path, 0o750), 0)
        let repository = try DeviceLicenceReceiptRepository(fileURL: root.appendingPathComponent("missing.receipt"))
        do { _ = try await repository.read(); XCTFail() }
        catch { XCTAssertEqual(error as? DeviceLicenceReceiptStorageFailure, .insecurePath) }
    }

    func testStrictStorageRecordRejectsUnknownExtraAndOversizedBytes() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("approved.receipt")
        let repository = try DeviceLicenceReceiptRepository(fileURL: url)
        _ = try await repository.replace("CLIPD1.YQ.Yg", expectedRevision: nil, permit: .init())
        let valid = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let bad = [Data(valid.replacingOccurrences(of: "\n1\n", with: "\n2\n").utf8),
                   Data((valid + "\n").utf8), Data(valid.prefix(12).utf8), Data(repeating: 65, count: 1201)]
        for bytes in bad {
            try bytes.write(to: url)
            do { _ = try await repository.read(); XCTFail("malformed record accepted") }
            catch { XCTAssertEqual(error as? DeviceLicenceReceiptStorageFailure, .corrupt) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testConcurrentIndependentRepositoriesHaveOnlyOneWinner() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("approved.receipt")
        let a = try DeviceLicenceReceiptRepository(fileURL: url), b = try DeviceLicenceReceiptRepository(fileURL: url)
        @Sendable func attempt(_ repository: DeviceLicenceReceiptRepository, _ envelope: String) async -> Bool {
            do { _ = try await repository.replace(envelope, expectedRevision: nil, permit: .init()); return true }
            catch {
                let failure = error as? DeviceLicenceReceiptStorageFailure
                XCTAssertTrue(failure == .busy || failure == .conflict, "unexpected storage result: \(String(describing: error))")
                return false
            }
        }
        async let first = attempt(a, "CLIPD1.YQ.Yg")
        async let second = attempt(b, "CLIPD1.Yw.ZA")
        let winners = await (first, second)
        XCTAssertNotEqual(winners.0, winners.1)
        let stored = try await a.read()
        XCTAssertEqual(stored.envelope, winners.0 ? "CLIPD1.YQ.Yg" : "CLIPD1.Yw.ZA")
    }

    func testExtendedACLIsRejectedEvenWhenModeBitsArePrivate() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("approved.receipt")
        let repository = try DeviceLicenceReceiptRepository(fileURL: url)
        _ = try await repository.replace("CLIPD1.YQ.Yg", expectedRevision: nil, permit: .init())
        let bytes = try Data(contentsOf: url)
        // Only this newly created fixture receives an ACL, to exercise rejection.
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", url.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        do { _ = try await repository.read(); XCTFail("extended ACL accepted") }
        catch { XCTAssertEqual(error as? DeviceLicenceReceiptStorageFailure, .insecurePath) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
#endif
