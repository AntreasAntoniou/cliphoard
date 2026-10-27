#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import Foundation

/// Authenticated purchaser data plus explicit local configuration. No receipt may
/// supply these values. Construction does not create directories or key material.
struct DeviceLicenceBootstrapApplicationConfiguration: Sendable {
    fileprivate let bootstrap: VerifiedDeviceLicenceBootstrap
    fileprivate let application: DeviceLicenceApplicationConfiguration

    init(bootstrap: VerifiedDeviceLicenceBootstrap, origin: URL, expectedDevicePublicKey: Data?,
         receiptFileURL: URL, identityKeychainService: String, identityKeychainAccount: String,
         resourceTimeout: TimeInterval) throws {
        if Task.isCancelled { throw DeviceLicenceBootstrapFailure.cancelled }
        do {
            let origin = try DeviceLicenceBootstrapRoutingTransport.canonicalOrigin(origin)
            if let pin = expectedDevicePublicKey, DeviceLicenceVerifier.canonicalPublicKey(pin) == nil {
                throw DeviceLicenceApplicationFailure.invalidConfiguration
            }
            // These constructors validate values only, without Keychain, file or
            // URLSession operations. Reuse the same boundaries as the session.
            _ = try DeviceIdentityKeychainStorage(service: identityKeychainService,
                account: identityKeychainAccount, calls: DeviceIdentitySystemKeychainCalls())
            _ = try DeviceLicenceReceiptRepository(fileURL: receiptFileURL)
            _ = try DeviceLicenceURLSessionTransport(resourceTimeout: resourceTimeout)
            self.bootstrap = bootstrap
            application = .init(origin: origin, entitlementID: bootstrap.entitlementID,
                entitlementHandle: bootstrap.activationHandle, issuerKeyID: bootstrap.receiptIssuerKeyID,
                issuerPublicKey: bootstrap.receiptIssuerPublicKey,
                expectedDevicePublicKey: expectedDevicePublicKey.map { Data(Array($0)) },
                receiptFileURL: receiptFileURL, identityKeychainService: identityKeychainService,
                identityKeychainAccount: identityKeychainAccount, resourceTimeout: resourceTimeout)
        } catch { throw DeviceLicenceApplicationFailure.invalidConfiguration }
    }
}

/// Builds a new inert session. It never replaces, stops or mutates another session,
/// and intentionally supplies no account-switch, bootstrap persistence or recovery API.
@MainActor
enum DeviceLicenceBootstrapApplication {
    static func makeSession(configuration: DeviceLicenceBootstrapApplicationConfiguration,
                            identityStorage: any DeviceIdentityStorage,
                            identityKeys: any DeviceIdentityKeyOperations,
                            transport: any DeviceLicenceApprovalTransport,
                            receiptIO: any DeviceLicenceReceiptFileIO = DeviceLicenceReceiptPOSIXIO(),
                            now: @escaping @Sendable () -> UInt64,
                            makeRequestID: @escaping @Sendable () -> Data) throws -> DeviceLicenceApplicationSession {
        if Task.isCancelled { throw DeviceLicenceBootstrapFailure.cancelled }
        do {
            let routed = try DeviceLicenceBootstrapRoutingTransport(bootstrap: configuration.bootstrap,
                origin: configuration.application.origin, transport: transport)
            return try DeviceLicenceApplicationSession(configuration: configuration.application,
                identityStorage: identityStorage, identityKeys: identityKeys, transport: routed,
                receiptIO: receiptIO, now: now, makeRequestID: makeRequestID)
        } catch { throw DeviceLicenceApplicationFailure.invalidConfiguration }
    }

    /// Concrete adapters remain lazy: no Keychain, enclave, filesystem or network
    /// operation until the caller explicitly acts on the returned session.
    static func native(configuration: DeviceLicenceBootstrapApplicationConfiguration) throws -> DeviceLicenceApplicationSession {
        if Task.isCancelled { throw DeviceLicenceBootstrapFailure.cancelled }
        do {
            return try makeSession(configuration: configuration,
                identityStorage: DeviceIdentityKeychainStorage(service: configuration.application.identityKeychainService,
                    account: configuration.application.identityKeychainAccount, calls: DeviceIdentitySystemKeychainCalls()),
                identityKeys: DeviceIdentitySecureEnclave(),
                transport: DeviceLicenceURLSessionTransport(resourceTimeout: configuration.application.resourceTimeout),
                now: { UInt64(min(Double(DeviceLicenceVerifier.maximumEpoch), max(1, Date().timeIntervalSince1970))) },
                makeRequestID: {
                    var uuid = UUID().uuid
                    return withUnsafeBytes(of: &uuid) { Data($0) }
                })
        } catch { throw DeviceLicenceApplicationFailure.invalidConfiguration }
    }
}
#endif
