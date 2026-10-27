#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import CryptoKit
import Foundation

enum DeviceIdentityFailure: Error, Equatable, Sendable {
    enum Unavailable: Equatable, Sendable { case secureHardware, storage, interactionRequired, secureKey }
    case unavailable(Unavailable)
    case missing, invalidRecord, identityChanged, invalidMessage, invalidProof, cancelled, superseded
}

struct DeviceIdentityMaterial: Equatable, Sendable {
    let publicKeyX963: Data
    /// An opaque, enclave-wrapped representation; never a software private key.
    let wrappedKey: Data
}

protocol DeviceIdentityStorage: Sendable {
    func read() async throws -> Data?
    /// Atomic insert only. False means another writer already owns this slot.
    func insertIfAbsent(_ record: Data) async throws -> Bool
}

protocol DeviceIdentityKeyOperations: Sendable {
    func isAvailable() async -> Bool
    func create() async throws -> DeviceIdentityMaterial
    func publicKey(for wrappedKey: Data) async throws -> Data
    func sign(_ message: Data, using wrappedKey: Data) async throws -> Data
}

/// Exact local storage format: purpose/version prefix, 65-byte public point,
/// four-byte big-endian wrapped-blob length, then the opaque blob. No migration.
enum DeviceIdentityRecord {
    static let prefix = Data("cliphoard.device-identity\n1\n".utf8)
    static let maximumWrappedBytes = 16_384
    static let maximumBytes = prefix.count + 65 + 4 + maximumWrappedBytes

    static func encode(_ key: DeviceIdentityMaterial) throws -> Data {
        guard DeviceLicenceVerifier.canonicalPublicKey(key.publicKeyX963) != nil,
              (1...maximumWrappedBytes).contains(key.wrappedKey.count) else {
            throw DeviceIdentityFailure.invalidRecord
        }
        let count = UInt32(key.wrappedKey.count)
        return prefix + key.publicKeyX963 + Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: count >> $0) }) + key.wrappedKey
    }

    static func decode(_ data: Data) throws -> DeviceIdentityMaterial {
        let header = prefix.count + 65 + 4
        guard data.count > header, data.count <= maximumBytes, data.starts(with: prefix) else {
            throw DeviceIdentityFailure.invalidRecord
        }
        let bytes = Array(data)
        let publicKey = Data(bytes[prefix.count..<(prefix.count + 65)])
        let count = bytes[(prefix.count + 65)..<header].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(count) == bytes.count - header else { throw DeviceIdentityFailure.invalidRecord }
        let material = DeviceIdentityMaterial(publicKeyX963: publicKey, wrappedKey: Data(bytes[header...]))
        guard try encode(material) == data else { throw DeviceIdentityFailure.invalidRecord }
        return material
    }
}

/// No startup work, defaults, network, receipt mutation or implicit key creation.
/// Newest load/create request wins. A failed or superseded request never replaces
/// the last verified identity; callers must retain their approved receipt too.
actor DeviceIdentity: DeviceLicenceKeyProvider {
    private let storage: any DeviceIdentityStorage
    private let keys: any DeviceIdentityKeyOperations
    private var pinnedPublicKey: Data?
    private var material: DeviceIdentityMaterial?
    private var generation: UInt64 = 0
    private(set) var lastFailure: DeviceIdentityFailure?
    var knownPublicKey: Data? { material?.publicKeyX963 }

    init(storage: any DeviceIdentityStorage, keys: any DeviceIdentityKeyOperations,
         expectedPublicKey: Data? = nil) throws {
        if let expectedPublicKey, DeviceLicenceVerifier.canonicalPublicKey(expectedPublicKey) == nil {
            throw DeviceIdentityFailure.invalidRecord
        }
        self.storage = storage; self.keys = keys; self.pinnedPublicKey = expectedPublicKey
    }

    func loadExisting() async -> Result<Data, DeviceIdentityFailure> { await resolve(allowCreation: false) }
    /// For an explicit first-activation action only. An expected/known identity
    /// forbids creation when its record disappears. No reset/delete API exists.
    func createIfAbsent() async -> Result<Data, DeviceIdentityFailure> { await resolve(allowCreation: true) }

    func cancelPending() {
        generation &+= 1
        lastFailure = .cancelled
    }

    func publicKeyX963() async throws -> Data {
        if let material { return material.publicKeyX963 }
        return try await loadExisting().get()
    }

    func signLicenceProof(_ message: Data) async throws -> Data {
        _ = try await publicKeyX963()
        guard let material else { throw DeviceIdentityFailure.missing }
        let ticket = generation
        do {
            try check(ticket)
            guard Self.validProofMessage(message, publicKey: material.publicKeyX963) else {
                throw DeviceIdentityFailure.invalidMessage
            }
            let raw = try await keys.sign(message, using: material.wrappedKey)
            try check(ticket)
            guard raw.count == 64,
                  let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
                  let publicKey = DeviceLicenceVerifier.canonicalPublicKey(material.publicKeyX963),
                  publicKey.isValidSignature(signature, for: message) else {
                throw DeviceIdentityFailure.invalidProof
            }
            lastFailure = nil
            return raw
        } catch {
            throw remember(error, ticket: ticket)
        }
    }

    private func resolve(allowCreation: Bool) async -> Result<Data, DeviceIdentityFailure> {
        generation &+= 1
        let ticket = generation
        do {
            try check(ticket)
            let available = await keys.isAvailable()
            try check(ticket)
            guard available else { throw DeviceIdentityFailure.unavailable(.secureHardware) }
            var record = try await storage.read()
            try check(ticket)
            if record == nil {
                guard allowCreation, pinnedPublicKey == nil else { throw DeviceIdentityFailure.missing }
                let candidate = try await keys.create()
                try check(ticket)
                let encoded = try DeviceIdentityRecord.encode(candidate)
                let candidatePublicKey = try await keys.publicKey(for: candidate.wrappedKey)
                try check(ticket)
                guard candidatePublicKey == candidate.publicKeyX963 else { throw DeviceIdentityFailure.invalidRecord }
                _ = try await storage.insertIfAbsent(encoded)
                try check(ticket)
                // Never publish a newly created key until the durable winner is
                // read back. A competing insertion may select a different key.
                record = try await storage.read()
                try check(ticket)
                guard record != nil else { throw DeviceIdentityFailure.unavailable(.storage) }
            }
            let restored = try DeviceIdentityRecord.decode(record!)
            if let pinnedPublicKey, pinnedPublicKey != restored.publicKeyX963 {
                throw DeviceIdentityFailure.identityChanged
            }
            let actualPublicKey = try await keys.publicKey(for: restored.wrappedKey)
            try check(ticket)
            guard actualPublicKey == restored.publicKeyX963,
                  DeviceLicenceVerifier.canonicalPublicKey(actualPublicKey) != nil else {
                throw DeviceIdentityFailure.invalidRecord
            }
            material = restored
            pinnedPublicKey = actualPublicKey
            lastFailure = nil
            return .success(actualPublicKey)
        } catch {
            return .failure(remember(error, ticket: ticket))
        }
    }

    private func check(_ ticket: UInt64) throws {
        guard ticket == generation else { throw DeviceIdentityFailure.superseded }
        guard !Task.isCancelled else { throw DeviceIdentityFailure.cancelled }
    }

    private func remember(_ error: Error, ticket: UInt64) -> DeviceIdentityFailure {
        guard ticket == generation else { return .superseded }
        let failure = error as? DeviceIdentityFailure ?? .unavailable(.secureKey)
        lastFailure = failure
        return failure
    }

    private static func validProofMessage(_ message: Data, publicKey: Data) -> Bool {
        guard message.count <= 1024, let text = String(data: message, encoding: .ascii) else { return false }
        let fields = text.components(separatedBy: "\n")
        func canonical(_ field: String, count: Int) -> Bool {
            guard field.utf8.count == (count * 8 + 5) / 6 else { return false }
            var value = field.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            value += String(repeating: "=", count: (4 - value.utf8.count % 4) % 4)
            guard let data = Data(base64Encoded: value), data.count == count else { return false }
            return DeviceLicenceVerifier.encode(data) == field
        }
        if fields.count == 4 {
            return fields[0] == DeviceLicenceVerifier.localProofPurpose && fields[1] == "1"
                && canonical(fields[2], count: 32) && canonical(fields[3], count: 32)
        }
        guard fields.count == 11, fields[0] == "cliphoard.device-approval", fields[1] == "1",
              fields[2] == DeviceLicenceVerifier.algorithm, canonical(fields[3], count: 16),
              fields[4] == DeviceLicenceVerifier.encode(publicKey),
              fields[5] == DeviceLicenceVerifier.encode(Data(SHA256.hash(data: publicKey))),
              canonical(fields[6], count: 16), canonical(fields[7], count: 32),
              let epoch = UInt64(fields[8]), epoch > 0, epoch <= DeviceLicenceVerifier.maximumEpoch,
              String(epoch) == fields[8], canonical(fields[9], count: 32), canonical(fields[10], count: 16) else { return false }
        return true
    }
}
#endif
