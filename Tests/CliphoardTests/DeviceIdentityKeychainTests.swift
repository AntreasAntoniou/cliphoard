#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import CryptoKit
import LocalAuthentication
import Security
import XCTest
@testable import Cliphoard

final class DeviceIdentityFakeKeychainCalls: DeviceIdentityKeychainCalls, @unchecked Sendable {
    private let lock = NSLock()
    var readStatus: OSStatus = errSecItemNotFound
    var readValue: Any?
    var addStatus: OSStatus = errSecSuccess
    private(set) var queries: [[String: Any]] = []
    private(set) var additions: [[String: Any]] = []
    private(set) var calledOnMain = false
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        lock.lock(); defer { lock.unlock() }
        calledOnMain = calledOnMain || Thread.isMainThread
        queries.append(query); return (readStatus, readValue)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        calledOnMain = calledOnMain || Thread.isMainThread
        additions.append(attributes); return addStatus
    }
}

final class DeviceIdentityKeychainTests: XCTestCase {
    private func store(_ calls: DeviceIdentityFakeKeychainCalls) throws -> DeviceIdentityKeychainStorage {
        try DeviceIdentityKeychainStorage(service: "synthetic.device-identity", account: "v1", calls: calls)
    }
    private func record() throws -> Data {
        try DeviceIdentityRecord.encode(.init(publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation,
                                              wrappedKey: Data([1, 2, 3])))
    }

    @MainActor func testFakeNativeCallsRunOffMainWithDeviceOnlyNoninteractiveScope() async throws {
        let calls = DeviceIdentityFakeKeychainCalls(), bytes = try record()
        let adapter = try store(calls)
        let missing = try await adapter.read(); XCTAssertNil(missing)
        let inserted = try await adapter.insertIfAbsent(bytes); XCTAssertTrue(inserted)
        XCTAssertFalse(calls.calledOnMain)
        let query = try XCTUnwrap(calls.queries.first), addition = try XCTUnwrap(calls.additions.first)
        for attributes in [query, addition] {
            XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
            XCTAssertEqual(attributes[kSecAttrService as String] as? String, "synthetic.device-identity")
            XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "v1")
            XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(attributes[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertTrue(try XCTUnwrap(attributes[kSecUseAuthenticationContext as String] as? LAContext).interactionNotAllowed)
            XCTAssertNil(attributes[kSecAttrAccessGroup as String])
        }
        XCTAssertEqual(addition[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(addition[kSecValueData as String] as? Data, bytes)
        XCTAssertNil(query[kSecValueData as String])
    }

    func testDuplicateReturnsExistingWithoutUpdateOrDeleteAndFailuresAreTyped() async throws {
        let calls = DeviceIdentityFakeKeychainCalls(), adapter = try store(calls), bytes = try record()
        calls.addStatus = errSecDuplicateItem
        let inserted = try await adapter.insertIfAbsent(bytes); XCTAssertFalse(inserted)
        for status in [errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecNotAvailable] {
            calls.readStatus = status
            do { _ = try await adapter.read(); XCTFail("status must fail closed") }
            catch { XCTAssertEqual(error as? DeviceIdentityFailure,
                .unavailable(status == errSecNotAvailable ? .storage : .interactionRequired)) }
        }
        XCTAssertEqual(calls.additions.count, 1)
    }

    func testWrongNativeDataAndOversizedRecordsAreRejectedWithoutRepair() async throws {
        let calls = DeviceIdentityFakeKeychainCalls(), adapter = try store(calls)
        calls.readStatus = errSecSuccess
        for value in ["wrong type" as Any, Data(repeating: 0, count: DeviceIdentityRecord.maximumBytes + 1)] {
            calls.readValue = value
            do { _ = try await adapter.read(); XCTFail("bad storage data accepted") }
            catch { XCTAssertEqual(error as? DeviceIdentityFailure, .invalidRecord) }
        }
        do { _ = try await adapter.insertIfAbsent(Data([1])); XCTFail("bad record inserted") }
        catch { XCTAssertEqual(error as? DeviceIdentityFailure, .invalidRecord) }
        XCTAssertTrue(calls.additions.isEmpty)
    }

    func testSuccessfulReadAndInsertErrorDoNotUseFallbackStore() async throws {
        let calls = DeviceIdentityFakeKeychainCalls(), adapter = try store(calls), bytes = try record()
        calls.readStatus = errSecSuccess; calls.readValue = bytes
        let actual = try await adapter.read(); XCTAssertEqual(actual, bytes)
        calls.addStatus = errSecMissingEntitlement
        do { _ = try await adapter.insertIfAbsent(bytes); XCTFail("missing entitlement accepted") }
        catch { XCTAssertEqual(error as? DeviceIdentityFailure, .unavailable(.storage)) }
        XCTAssertEqual(calls.queries.count, 1); XCTAssertEqual(calls.additions.count, 1)
    }

    func testInvalidNamespaceDoesNoNativeWork() {
        let calls = DeviceIdentityFakeKeychainCalls()
        for service in ["", "email@example.test", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(try DeviceIdentityKeychainStorage(service: service, account: "v1", calls: calls))
        }
        XCTAssertTrue(calls.queries.isEmpty); XCTAssertTrue(calls.additions.isEmpty)
    }
}
#endif
