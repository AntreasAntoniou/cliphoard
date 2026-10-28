#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import XCTest
import Security
import Darwin
@testable import Cliphoard

private final class ReleaseKeychainSpy: DeviceIdentityKeychainCalls, @unchecked Sendable {
    let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        lock.lock(); count += 1; lock.unlock(); return (errSecItemNotFound, nil)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.lock(); count += 1; lock.unlock(); return errSecNotAvailable
    }
}
final class DeviceLicenceReleaseConfigurationTests: XCTestCase {
    func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/cliphoard-release-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor func testConstructionIsInertAndWrongBundleFailsClosed() throws {
        let root = try directory(), spy = ReleaseKeychainSpy()
        let runtime = DeviceLicenceReleaseConfiguration.makeRuntime(bundleIdentifier: "ai.a2-labs.cliphoard", applicationSupport: root, keychain: spy)
#if CLIPHOARD_DEVICE_LICENSING_CONFIGURED
        XCTAssertTrue(runtime?.isConfigured == true)
#else
        XCTAssertNil(runtime)
#endif
        XCTAssertNil(DeviceLicenceReleaseConfiguration.makeRuntime(bundleIdentifier: "test.host", applicationSupport: root, keychain: spy))
        XCTAssertEqual(spy.calls, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    @MainActor func testInvalidPathFailsBeforeAnyNativeCall() throws {
        let spy = ReleaseKeychainSpy()
        for path in [URL(string: "https://example.invalid/")!, URL(string: "file:///private/tmp?x=1")!] {
            XCTAssertNil(DeviceLicenceReleaseConfiguration.makeRuntime(bundleIdentifier: "ai.a2-labs.cliphoard", applicationSupport: path, keychain: spy))
        }
        XCTAssertEqual(spy.calls, 0)
    }
    @MainActor func testInvalidSetupCannotCreateStorageOrCallKeychain() async throws {
        let root = try directory(), spy = ReleaseKeychainSpy()
        guard let runtime = DeviceLicenceReleaseConfiguration.makeRuntime(bundleIdentifier: "ai.a2-labs.cliphoard", applicationSupport: root, keychain: spy) else {
#if CLIPHOARD_DEVICE_LICENSING_CONFIGURED
            return XCTFail("configured runtime missing")
#else
            return
#endif
        }
        await runtime.start(publishReceipt: { _ in XCTFail("not approved") })?.value
        XCTAssertEqual(spy.calls, 1) // Explicit restore checks only the selected bootstrap item.
        await runtime.importBootstrap("invalid")?.value
        XCTAssertEqual(spy.calls, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        runtime.stop()
    }
    func testPrivateDirectoryPreparationIsIdempotentAndPreservesContents() throws {
        let root = try directory(), location = try DeviceLicenceReleaseDirectory(applicationSupport: root)
        try location.prepare()
        let file = location.receiptURL.deletingLastPathComponent().appendingPathComponent("retained")
        try Data("retained".utf8).write(to: file)
        try location.prepare()
        XCTAssertEqual(try Data(contentsOf: file), Data("retained".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    func testUnsafeExistingDirectoryAndSymlinkAreNotRepaired() throws {
        let root = try directory(), location = try DeviceLicenceReleaseDirectory(applicationSupport: root)
        let leaf = location.receiptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try location.prepare())
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: leaf.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        try FileManager.default.removeItem(at: leaf)
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: root)
        XCTAssertThrowsError(try location.prepare())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: leaf.path), root.path)
    }
}
#endif
