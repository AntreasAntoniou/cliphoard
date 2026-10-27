#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import Foundation
import CryptoKit

struct DeviceLicenceRecoveryBindings: Sendable {
    let issuerKeyID: String
    let issuerPublicKey: Data
    let entitlementID: String
    let devicePublicKey: Data
}
enum DeviceLicenceRecoveryFailure: Error, Equatable, Sendable {
    case missing, invalidBindings, bindingMismatch, cancelled, superseded
    case verification(DeviceLicenceFailure)
    case identity(DeviceIdentityFailure)
    case storage(DeviceLicenceReceiptStorageFailure)
}
actor DeviceLicenceRecovery {
    private let storage: any DeviceLicenceReceiptStorage
    private let identity: DeviceIdentity
    private let bindings: DeviceLicenceRecoveryBindings
    private var generation: UInt64 = 0
    private var pendingPermit: DeviceLicenceReceiptPermit?
    private(set) var receipt: DeviceLicenceReceipt?
    private(set) var lastFailure: DeviceLicenceRecoveryFailure?
    init(storage: any DeviceLicenceReceiptStorage, identity: DeviceIdentity,
         bindings: DeviceLicenceRecoveryBindings) throws {
        let keyID = Array(bindings.issuerKeyID.utf8)
        func alphaNumeric(_ b: UInt8) -> Bool { (97...122).contains(b) || (48...57).contains(b) }
        let encoded = bindings.entitlementID.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard (1...32).contains(keyID.count), keyID.first.map(alphaNumeric) == true,
              keyID.allSatisfy({ alphaNumeric($0) || $0 == 45 || $0 == 95 }),
              bindings.entitlementID.utf8.count == 22, let entitlement = Data(base64Encoded: encoded + "=="),
              entitlement.count == 16, DeviceLicenceVerifier.encode(entitlement) == bindings.entitlementID,
              DeviceLicenceVerifier.canonicalPublicKey(bindings.issuerPublicKey) != nil,
              DeviceLicenceVerifier.canonicalPublicKey(bindings.devicePublicKey) != nil else {
            throw DeviceLicenceRecoveryFailure.invalidBindings
        }
        self.storage = storage; self.identity = identity; self.bindings = bindings
    }
    func restore() async -> Result<DeviceLicenceReceipt, DeviceLicenceRecoveryFailure> { await run(importing: nil) }
    func accept(_ envelope: String) async -> Result<DeviceLicenceReceipt, DeviceLicenceRecoveryFailure> { await run(importing: envelope) }
    func cancelPending() {
        generation &+= 1; pendingPermit?.cancel(); lastFailure = .cancelled
    }

    private func run(importing envelope: String?) async -> Result<DeviceLicenceReceipt, DeviceLicenceRecoveryFailure> {
        pendingPermit?.cancel(); generation &+= 1
        let ticket = generation, permit = DeviceLicenceReceiptPermit()
        pendingPermit = permit
        return await withTaskCancellationHandler {
            do {
                try check(ticket)
                let prior = try await storage.read()
                try check(ticket); try validate(prior)
                var priorReceipt: DeviceLicenceReceipt?
                if let previous = prior.envelope { priorReceipt = try await verify(previous, ticket: ticket) }
                guard let envelope else {
                    guard let priorReceipt else { throw DeviceLicenceRecoveryFailure.missing }
                    return publish(priorReceipt)
                }
                if envelope == prior.envelope, let priorReceipt { return publish(priorReceipt) }
                let approved = try await verify(envelope, ticket: ticket)
                let stored = try await storage.replace(envelope, expectedRevision: prior.revision, permit: permit)
                try check(ticket)
                guard stored.envelope == envelope, stored.revision?.count == 32 else {
                    throw DeviceLicenceReceiptStorageFailure.commitUncertain
                }
                return publish(approved)
            } catch {
                guard ticket == generation else { return .failure(.superseded) }
                let failure: DeviceLicenceRecoveryFailure
                if Task.isCancelled { failure = .cancelled }
                else if let known = error as? DeviceLicenceRecoveryFailure { failure = known }
                else if let store = error as? DeviceLicenceReceiptStorageFailure { failure = .storage(store) }
                else { failure = .storage(.io) }
                lastFailure = failure
                return .failure(failure)
            }
        } onCancel: { permit.cancel() }
    }
    private func verify(_ envelope: String, ticket: UInt64) async throws -> DeviceLicenceReceipt {
        let key: Data
        do { key = try await identity.loadExisting().get() }
        catch { throw DeviceLicenceRecoveryFailure.identity(error) }
        try check(ticket)
        guard key == bindings.devicePublicKey else { throw DeviceLicenceRecoveryFailure.bindingMismatch }
        let result = await DeviceLicenceVerifier.verify(envelope, using: identity,
            trustedIssuers: [bindings.issuerKeyID: bindings.issuerPublicKey])
        try check(ticket)
        let verified: DeviceLicenceReceipt
        do { verified = try result.get() }
        catch { throw DeviceLicenceRecoveryFailure.verification(error) }
        guard verified.entitlementID == bindings.entitlementID, verified.issuerKeyID == bindings.issuerKeyID,
              verified.deviceKeyHash == DeviceLicenceVerifier.encode(Data(SHA256.hash(data: bindings.devicePublicKey))) else {
            throw DeviceLicenceRecoveryFailure.bindingMismatch
        }
        return verified
    }
    private func validate(_ snapshot: DeviceLicenceReceiptSnapshot) throws {
        guard (snapshot.envelope == nil && snapshot.revision == nil)
            || (snapshot.envelope != nil && snapshot.revision?.count == 32) else {
            throw DeviceLicenceReceiptStorageFailure.corrupt
        }
    }
    private func check(_ ticket: UInt64) throws {
        guard generation == ticket else { throw DeviceLicenceRecoveryFailure.superseded }
        guard !Task.isCancelled else { throw DeviceLicenceRecoveryFailure.cancelled }
    }
    private func publish(_ approved: DeviceLicenceReceipt) -> Result<DeviceLicenceReceipt, DeviceLicenceRecoveryFailure> {
        receipt = approved; lastFailure = nil; return .success(approved)
    }
}
#endif
