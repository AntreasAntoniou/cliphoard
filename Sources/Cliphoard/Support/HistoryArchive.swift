import Foundation
import CommonCrypto
import CryptoKit
import Security

/// The `.cliphoard` container format — nothing but bytes.
///
/// DELIBERATELY PURE. This file knows no `ClipStore`, no `Database`, no `ClipItem`, no
/// AppKit and no `UserDefaults`. That is what makes the truncation, tamper and KDF tests
/// real unit tests rather than end-to-end tests wearing a unit test's name: every refusal
/// below can be provoked from a byte array, on any machine, with no keychain, in
/// milliseconds. `HistoryReaper` is the precedent — its refusals are pure functions for
/// exactly the same reason, after a rule that could only be exercised in its safe state
/// turned out not to be a tested rule at all.
///
/// ```
/// [ header 48 B, CLEAR, authenticated as AAD by everything below ]
/// [ sealed summary: 1040 B  = GCM(1024 B padded JSON), nonce counter 0 ]
/// [ chunk frame 1 ][ chunk frame 2 ] … [ chunk frame N, isFinal=1 ]
/// EOF — any trailing byte is a refusal
/// ```
///
/// Two properties are worth stating because they are the ones a reviewer should check:
///
///   1. **Nothing personal is outside the 48-byte header**, and the header carries no clip
///      count, no dates, no machine name and no sizes. Opening the sealed summary IS the
///      passphrase check — one mechanism doing two jobs, rather than a plaintext preview
///      block that would leak the history's shape to anyone holding the file.
///   2. **`summaryLen` is the constant 1040 in v1** and a v1 reader refuses any other
///      value. A variable-length summary would leak its own length, which correlates with
///      the machine-name length and the digit count of the clip count. The plaintext is
///      NUL-padded to exactly 1024 bytes and the padding is trimmed before parsing.
enum HistoryArchive {

    // MARK: - Constants (the numbers the tests derive from, never restate)

    static let magic = Data("CLIPHRD1".utf8)
    static let formatVersion: UInt16 = 1
    /// PBKDF2-HMAC-SHA256 → HKDF-SHA256-Expand. `2` is RESERVED for Argon2id, which stays
    /// out of 1.0.1 on purpose: a vendored or SPM Argon2 adds a `Package.resolved` pin,
    /// which drags in a distribution-manifest classification line and (for an MIT package)
    /// a verbatim upstream licence section — plus an unaudited memory-hard implementation
    /// inside the one product whose pitch is that it holds your secrets.
    static let kdfPBKDF2SHA256: UInt8 = 1
    static let aeadAESGCM: UInt8 = 1
    static let headerLength = 48
    /// The floor is COMPILED IN. It is never read from the file, because a parameter a
    /// file may lower is not a parameter, it is a suggestion.
    static let kdfRoundsFloor: UInt32 = 600_000
    /// What the writer will calibrate up to.
    static let kdfRoundsCeiling: UInt32 = 3_000_000
    /// What a reader will accept — wider than the writer's ceiling, so a file made on a
    /// much faster Mac still opens here.
    static let kdfRoundsReaderMax: UInt32 = 10_000_000
    static let kdfCalibrationTargetMilliseconds: UInt32 = 600
    static let kdfSaltLength = 16
    static let noncePrefixLength = 4
    static let fileKeyLength = 32
    /// Pinned by a test. Changing it changes every derived key, so it is a format
    /// constant, not a string literal someone may tidy.
    static let hkdfInfo = "cliphoard/export/v1/file-key"

    static let summaryPlaintextLength = 1024
    /// 1024 ciphertext + 16 GCM tag. Constant for every v1 file, by design.
    static let summaryLength: UInt32 = 1040

    static let defaultChunkSize: UInt32 = 1_048_576
    static let minChunkSize: UInt32 = 65_536
    static let maxChunkSize: UInt32 = 8_388_608

    /// A single record body may not exceed this. Checked BEFORE the allocation, so a
    /// hostile 2^63 length is a refusal rather than a nine-exabyte `Data(count:)`.
    static let maxRecordBody = 64 * 1024 * 1024

    /// The hard floor, enforced in `HistoryArchiveIO` and not only in the passphrase
    /// sheet. The CLI bypasses the UI entirely, and a policy enforced at one of two
    /// entry points is precisely the bug shape this codebase writes tests against.
    static let passphraseMinimumLength = 12

    static let fileExtension = "cliphoard"
    static let uti = "io.antreas.cliphoard.archive"

    // MARK: - Errors — one case per refusal, each with its own sentence

    enum ArchiveError: Error, Equatable {
        case passphraseTooShort(Int)
        case notAnArchive
        case futureVersion(UInt16)
        case unsupportedKDF(UInt8)
        case unsupportedAEAD(UInt8)
        case iterationsOutOfRange(UInt32)
        case chunkSizeOutOfRange(UInt32)
        case unexpectedSummaryLength(UInt32)
        case reservedBytesNotZero
        case keyDerivationFailed
        case randomnessUnavailable
        case truncated(String)
        /// The summary would not open. Deliberately ambiguous, and honestly worded: the
        /// header is authenticated only AS the summary's AAD, so a corrupted header and a
        /// wrong passphrase are indistinguishable here. A separate header MAC would need
        /// a key before the KDF, which is circular.
        case wrongPassphraseOrDamaged
        /// A failure AFTER the summary opened. The key has already proven itself, so this
        /// one says "damaged or modified" only — never "wrong passphrase".
        case damagedOrModified(String)
        case trailingBytes
        case malformedRecord(String)
        case unknownRecordType(UInt8)
        case payloadHashMismatch(String)
        case danglingPayloadReference(String)
        case manifestDisagreesWithSummary(String)
        case storeFrozen
        case historyNotProvenComplete
        case unreadableContent(clips: Int, payloads: Int)
        case licenceRequired
        case cannotWrite(String)
        case cannotRead(String)
        case noDatabase

        var message: String {
            switch self {
            case .passphraseTooShort(let n):
                return "That passphrase is \(n) character\(n == 1 ? "" : "s") long. Use at "
                     + "least \(HistoryArchive.passphraseMinimumLength) — this file's only "
                     + "protection is the passphrase, and there is no recovery."
            case .notAnArchive:
                return "That is not a Cliphoard export."
            case .futureVersion(let v):
                return "This file was made by a newer Cliphoard (format version \(v)). "
                     + "Update Cliphoard and try again."
            case .unsupportedKDF(let id):
                return "This file uses a key-stretching method this build does not know "
                     + "(id \(id))."
            case .unsupportedAEAD(let id):
                return "This file uses an encryption method this build does not know "
                     + "(id \(id))."
            case .iterationsOutOfRange(let n):
                return "This file claims \(n) key-stretching rounds, which is outside the "
                     + "range Cliphoard accepts (\(HistoryArchive.kdfRoundsFloor)–"
                     + "\(HistoryArchive.kdfRoundsReaderMax)). Refusing rather than "
                     + "opening it with weakened protection."
            case .chunkSizeOutOfRange(let n):
                return "This file declares a \(n)-byte block size, which is outside the "
                     + "range Cliphoard accepts. Refusing before allocating anything."
            case .unexpectedSummaryLength(let n):
                return "This file's summary block is \(n) bytes; every version-1 export "
                     + "has exactly \(HistoryArchive.summaryLength). Refusing."
            case .reservedBytesNotZero:
                return "This file sets header bytes that must be zero. Refusing rather "
                     + "than silently ignoring them."
            case .keyDerivationFailed:
                return "The passphrase could not be turned into a key on this Mac."
            case .randomnessUnavailable:
                return "The system random number generator refused. Nothing was written."
            case .truncated(let what):
                return "This file is incomplete — \(what). A partly-read history is worse "
                     + "than none, so nothing was imported."
            case .wrongPassphraseOrDamaged:
                return "That passphrase doesn't open this file — or the file has been "
                     + "damaged or modified."
            case .damagedOrModified(let what):
                return "This file is damaged or was modified (\(what)). The passphrase was "
                     + "correct; the bytes are not. Nothing was imported."
            case .trailingBytes:
                return "There are extra bytes after the end of this file. Refusing."
            case .malformedRecord(let what):
                return "This file's contents could not be read (\(what))."
            case .unknownRecordType(let t):
                return "This file contains a record type this build does not know (\(t))."
            case .payloadHashMismatch(let name):
                return "An image in this file does not match its own content hash "
                     + "(\(name)). Refusing."
            case .danglingPayloadReference(let name):
                return "A clip in this file refers to an image the file does not contain "
                     + "(\(name)). Refusing rather than importing a broken history."
            case .manifestDisagreesWithSummary(let what):
                return "This file's summary and its contents disagree (\(what)). Refusing."
            case .storeFrozen:
                return "Cliphoard can't read its own history right now, so it can neither "
                     + "export it nor add to it. Nothing has been deleted."
            case .historyNotProvenComplete:
                return "The history could not be read in full. An export of a partial read "
                     + "would silently lose clips, so nothing was written."
            case .unreadableContent(let clips, let payloads):
                return "\(clips) clip\(clips == 1 ? "" : "s") and \(payloads) "
                     + "image\(payloads == 1 ? "" : "s") in this history cannot be "
                     + "decrypted by this Mac, so they cannot be exported. Run Cliphoard "
                     + "with --crypto-diagnostics to see why. Export the rest only if you "
                     + "accept that they will be missing."
            case .licenceRequired:
                return "Moving your history to another Mac is a Pro feature."
            case .cannotWrite(let what):
                return "Could not write the export (\(what)). Nothing was left behind."
            case .cannotRead(let what):
                return "Could not read that file (\(what))."
            case .noDatabase:
                return "Cliphoard has no open database, so there is nothing to export."
            }
        }
    }

    // MARK: - Big-endian helpers. ONE rule, stated once, tested once.

    static func be16(_ v: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)])
    }

    static func be32(_ v: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
              UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)])
    }

    static func be64(_ v: UInt64) -> Data {
        var out = Data(capacity: 8)
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
        }
        return out
    }

    static func readBE16(_ d: Data, at i: Int) -> UInt16 {
        let b = d.startIndex + i
        return UInt16(d[b]) << 8 | UInt16(d[b + 1])
    }

    static func readBE32(_ d: Data, at i: Int) -> UInt32 {
        let b = d.startIndex + i
        return UInt32(d[b]) << 24 | UInt32(d[b + 1]) << 16 | UInt32(d[b + 2]) << 8 | UInt32(d[b + 3])
    }

    static func readBE64(_ d: Data, at i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = v << 8 | UInt64(d[d.startIndex + i + k]) }
        return v
    }

    // MARK: - Randomness

    /// CSPRNG, and a refusal rather than a fallback if it is unavailable. A weak salt is
    /// not a degraded export, it is an export with no protection.
    static func randomBytes(_ count: Int) -> Data? {
        var out = Data(count: count)
        let ok = out.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        return ok == errSecSuccess ? out : nil
    }

    // MARK: - Header

    struct Header: Equatable {
        var version: UInt16 = HistoryArchive.formatVersion
        var kdfID: UInt8 = HistoryArchive.kdfPBKDF2SHA256
        var aeadID: UInt8 = HistoryArchive.aeadAESGCM
        var kdfIterations: UInt32
        var kdfSalt: Data
        var noncePrefix: Data
        var chunkSize: UInt32
        var summaryLen: UInt32 = HistoryArchive.summaryLength
        var reserved: UInt32 = 0

        var encoded: Data {
            var d = Data(capacity: HistoryArchive.headerLength)
            d.append(HistoryArchive.magic)
            d.append(HistoryArchive.be16(version))
            d.append(kdfID)
            d.append(aeadID)
            d.append(HistoryArchive.be32(kdfIterations))
            d.append(kdfSalt)
            d.append(noncePrefix)
            d.append(HistoryArchive.be32(chunkSize))
            d.append(HistoryArchive.be32(summaryLen))
            d.append(HistoryArchive.be32(reserved))
            return d
        }

        /// Every field validated, each with its own message, BEFORE anything is allocated
        /// on the strength of it. `chunkSize` and `summaryLen` in particular: a reader
        /// that allocates first and validates second is a reader that can be made to
        /// allocate four gigabytes by five bytes of hostile input.
        static func decode(_ raw: Data) throws -> Header {
            guard raw.count >= HistoryArchive.headerLength else {
                throw ArchiveError.truncated("it is shorter than the 48-byte header")
            }
            let d = Data(raw.prefix(HistoryArchive.headerLength))
            guard d.prefix(8) == HistoryArchive.magic else { throw ArchiveError.notAnArchive }
            let version = HistoryArchive.readBE16(d, at: 8)
            guard version == HistoryArchive.formatVersion else {
                throw ArchiveError.futureVersion(version)
            }
            let kdfID = d[d.startIndex + 10]
            guard kdfID == HistoryArchive.kdfPBKDF2SHA256 else {
                throw ArchiveError.unsupportedKDF(kdfID)
            }
            let aeadID = d[d.startIndex + 11]
            guard aeadID == HistoryArchive.aeadAESGCM else {
                throw ArchiveError.unsupportedAEAD(aeadID)
            }
            let iterations = HistoryArchive.readBE32(d, at: 12)
            guard iterations >= HistoryArchive.kdfRoundsFloor,
                  iterations <= HistoryArchive.kdfRoundsReaderMax else {
                throw ArchiveError.iterationsOutOfRange(iterations)
            }
            let chunkSize = HistoryArchive.readBE32(d, at: 36)
            guard chunkSize >= HistoryArchive.minChunkSize,
                  chunkSize <= HistoryArchive.maxChunkSize else {
                throw ArchiveError.chunkSizeOutOfRange(chunkSize)
            }
            let summaryLen = HistoryArchive.readBE32(d, at: 40)
            guard summaryLen == HistoryArchive.summaryLength else {
                throw ArchiveError.unexpectedSummaryLength(summaryLen)
            }
            let reserved = HistoryArchive.readBE32(d, at: 44)
            guard reserved == 0 else { throw ArchiveError.reservedBytesNotZero }
            return Header(version: version, kdfID: kdfID, aeadID: aeadID,
                          kdfIterations: iterations,
                          kdfSalt: Data(d[(d.startIndex + 16)..<(d.startIndex + 32)]),
                          noncePrefix: Data(d[(d.startIndex + 32)..<(d.startIndex + 36)]),
                          chunkSize: chunkSize, summaryLen: summaryLen, reserved: reserved)
        }
    }

    // MARK: - Key derivation

    /// Calibrated once per process, so two exports from the same run produce byte-identical
    /// header bytes 0..<16 and differ from offset 16 onward (fresh salt) — which makes
    /// "two exports of the same store differ" a test about randomness rather than a test
    /// about the calibrator's mood.
    static let calibratedIterations: UInt32 = calibrateIterations()

    static func calibrateIterations(
        targetMilliseconds: UInt32 = kdfCalibrationTargetMilliseconds) -> UInt32 {
        let raw = CCCalibratePBKDF(CCPBKDFAlgorithm(kCCPBKDF2), 32, kdfSaltLength,
                                  CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                  fileKeyLength, targetMilliseconds)
        // CCCalibratePBKDF reports failure as (unsigned)-1. Treat anything absurd as
        // "calibration unavailable" and fall back to the FLOOR, never below it.
        guard raw > 0, raw < UInt32.max / 2 else { return kdfRoundsFloor }
        let clamped = min(max(raw, kdfRoundsFloor), kdfRoundsCeiling)
        return max((clamped / 50_000) * 50_000, kdfRoundsFloor)
    }

    /// PBKDF2-HMAC-SHA256, then one HKDF expand for domain separation.
    ///
    /// **HKDF alone is the tempting wrong answer**, and it is named here so nobody
    /// "simplifies" to it: it sits right there in CryptoKit, which this codebase already
    /// imports, and it is a single fast extract-and-expand with NO work factor. Running it
    /// on a passphrase turns the file into an offline dictionary attack at line rate. The
    /// work factor is the whole point; the HKDF step below is only domain separation, so
    /// the master can never be reused for a second purpose by a future version.
    ///
    /// Passphrase handling: **Unicode NFC, UTF-8, no trimming.** The same `é` typed on two
    /// Macs can arrive composed or decomposed and would otherwise derive two different
    /// keys — a real cross-Mac bug class, and this file is designed to travel between
    /// Macs. Leading and trailing spaces are part of the passphrase.
    static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) -> SymmetricKey? {
        let normalized = passphrase.precomposedStringWithCanonicalMapping
        var pass = Array(normalized.utf8)
        guard !pass.isEmpty, !salt.isEmpty else { return nil }
        var derived = [UInt8](repeating: 0, count: fileKeyLength)
        defer {
            for i in pass.indices { pass[i] = 0 }
            for i in derived.indices { derived[i] = 0 }
        }
        let status: Int32 = pass.withUnsafeBufferPointer { passBuf in
            salt.withUnsafeBytes { saltBuf -> Int32 in
                guard let passBase = passBuf.baseAddress,
                      let saltBase = saltBuf.baseAddress else { return Int32(kCCParamError) }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(passBase).assumingMemoryBound(to: CChar.self),
                    passBuf.count,
                    saltBase.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                    &derived, derived.count)
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        let master = SymmetricKey(data: Data(derived))
        return HKDF<SHA256>.expand(pseudoRandomKey: master,
                                   info: Data(hkdfInfo.utf8),
                                   outputByteCount: fileKeyLength)
    }

    // MARK: - Passphrase policy

    /// Five groups of five base32 characters — 25 characters, 125 bits, written as 29
    /// with the separators — straight from `SecRandomCopyBytes`.
    ///
    /// **No wordlist, deliberately.** The EFF diceware lists are CC-BY-3.0, which under
    /// `DistributionLicenceTests` becomes an attribution obligation in
    /// `THIRD-PARTY-NOTICES.md`. Base32 from the system CSPRNG is self-authored, needs no
    /// attribution, and leaves the notices file untouched.
    ///
    /// The alphabet is RFC 4648 base32, and 32 divides 256 exactly, so masking a random
    /// byte to five bits is uniform — no rejection sampling, no modulo bias.
    static func generatePassphrase(groups: Int = 5, perGroup: Int = 5) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        guard let bytes = randomBytes(groups * perGroup) else { return nil }
        let chars = bytes.map { alphabet[Int($0 & 0x1f)] }
        return stride(from: 0, to: chars.count, by: perGroup)
            .map { String(chars[$0..<min($0 + perGroup, chars.count)]) }
            .joined(separator: "-")
    }

    /// 0 = below the hard floor (unusable), 1…4 = weak / fair / good / strong.
    ///
    /// A pure function of the string, so the meter in the sheet and any test agree by
    /// construction. It measures LENGTH and VARIETY and nothing else — no composition
    /// rules, which push people towards `Password1!` and buy nothing.
    static func passphraseStrength(_ s: String) -> Int {
        guard s.count >= passphraseMinimumLength else { return 0 }
        var classes = 0
        if s.contains(where: { $0.isLowercase }) { classes += 1 }
        if s.contains(where: { $0.isUppercase }) { classes += 1 }
        if s.contains(where: { $0.isNumber }) { classes += 1 }
        if s.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }
        let bitsPerChar: Double = [2.0, 4.7, 5.7, 6.0, 6.5][max(0, min(4, classes))]
        let bits = Double(s.count) * bitsPerChar
        switch bits {
        case ..<60:  return 1
        case ..<80:  return 2
        case ..<110: return 3
        default:     return 4
        }
    }

    static func strengthLabel(_ level: Int) -> String {
        ["too short", "weak", "fair", "good", "strong"][max(0, min(4, level))]
    }

    // MARK: - Byte sources

    /// Pull interface over a file or a `Data`. `read` may return FEWER bytes than asked
    /// for only at end of file; every caller treats a short read as a refusal.
    protocol ByteSource: AnyObject {
        func read(_ count: Int) throws -> Data
    }

    final class DataByteSource: ByteSource {
        private let data: Data
        private var offset = 0
        init(_ data: Data) { self.data = data }
        func read(_ count: Int) throws -> Data {
            let n = min(count, data.count - offset)
            guard n > 0 else { return Data() }
            let out = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + n))
            offset += n
            return out
        }
    }

    final class FileByteSource: ByteSource {
        private let handle: FileHandle
        init(_ handle: FileHandle) { self.handle = handle }
        func read(_ count: Int) throws -> Data {
            var out = Data()
            while out.count < count {
                guard let piece = try handle.read(upToCount: count - out.count),
                      !piece.isEmpty else { break }
                out.append(piece)
            }
            return out
        }
    }

    // MARK: - Chunk frames

    /// Seals the body as a sequence of authenticated frames.
    ///
    /// ```
    /// 4 B   plaintextLen : UInt32BE, 0 < L <= chunkSize
    /// 1 B   isFinal      : 0x00 or 0x01
    /// L+16  GCM ciphertext ‖ 16-byte tag
    ///
    /// nonce_i = noncePrefix(4) ‖ UInt64BE(i)                                  // 12 B
    /// AAD_i   = header[0..<48] ‖ UInt64BE(i) ‖ UInt8(isFinal) ‖ UInt32BE(L)   // 61 B
    /// ```
    ///
    /// The length prefix is bound into the AAD, and the final chunk is ALWAYS emitted with
    /// an explicit `isFinal` flag rather than inferred from the file length. Inferring is
    /// the design that passes every test except the one that matters: a file truncated
    /// exactly on a chunk boundary, where a length-inferring reader sees a perfectly valid
    /// smaller history.
    ///
    /// Nonce uniqueness is STRUCTURAL, not probabilistic: the key is unique per file (a
    /// fresh 16-byte salt), and within a file the nonce is a fresh 4-byte prefix plus a
    /// strictly increasing counter. At 1 MiB per invocation this sits five orders of
    /// magnitude under the 64 GiB per-(key, nonce) limit.
    final class ChunkWriter {
        private let key: SymmetricKey
        private let noncePrefix: Data
        private let header: Data
        let chunkSize: Int
        private let sink: (Data) throws -> Void
        private var buffer = Data()
        private var index: UInt64 = 0
        private(set) var plaintextCount = 0

        init(key: SymmetricKey, noncePrefix: Data, header: Data, chunkSize: Int,
             sink: @escaping (Data) throws -> Void) {
            self.key = key; self.noncePrefix = noncePrefix; self.header = header
            self.chunkSize = chunkSize; self.sink = sink
        }

        /// Buffers, and emits a chunk only once MORE bytes are known to follow. That is
        /// what keeps `finish()` from ever having to emit an empty final frame, which the
        /// `0 < L` rule forbids.
        func append(_ bytes: Data) throws {
            guard !bytes.isEmpty else { return }
            plaintextCount += bytes.count
            var input = bytes[...]
            if !buffer.isEmpty {
                let need = chunkSize - buffer.count
                if input.count <= need { buffer.append(contentsOf: input); return }
                buffer.append(contentsOf: input.prefix(need))
                input = input.dropFirst(need)
                try emit(buffer, isFinal: false)
                buffer = Data()
            }
            while input.count > chunkSize {
                try emit(Data(input.prefix(chunkSize)), isFinal: false)
                input = input.dropFirst(chunkSize)
            }
            buffer = Data(input)
        }

        /// How many plaintext bytes would still have to arrive to land exactly on a chunk
        /// boundary. The pad record uses this so the final chunk is always full — which
        /// buys 1 MiB of size granularity and, stated honestly, nothing more.
        func bytesToNextBoundary(afterAdding extra: Int) -> Int {
            let total = plaintextCount + extra
            return (chunkSize - (total % chunkSize)) % chunkSize
        }

        func finish() throws {
            guard !buffer.isEmpty else {
                throw ArchiveError.malformedRecord("an export with an empty body")
            }
            try emit(buffer, isFinal: true)
            buffer = Data()
        }

        private func emit(_ plain: Data, isFinal: Bool) throws {
            index += 1
            let length = UInt32(plain.count)
            var aad = header
            aad.append(HistoryArchive.be64(index))
            aad.append(isFinal ? 1 : 0)
            aad.append(HistoryArchive.be32(length))
            guard let nonce = try? AES.GCM.Nonce(data: noncePrefix + HistoryArchive.be64(index)),
                  let box = try? AES.GCM.seal(plain, using: key, nonce: nonce,
                                              authenticating: aad)
            else { throw ArchiveError.cannotWrite("a block could not be sealed") }
            var frame = Data(capacity: 5 + plain.count + 16)
            frame.append(HistoryArchive.be32(length))
            frame.append(isFinal ? 1 : 0)
            frame.append(box.ciphertext)
            frame.append(box.tag)
            try sink(frame)
        }
    }

    /// The reader half. Every refusal in the failure matrix lands here or in `Header.decode`.
    final class ChunkReader {
        private let source: ByteSource
        private let key: SymmetricKey
        private let noncePrefix: Data
        private let header: Data
        private let chunkSize: Int
        private var index: UInt64 = 0
        private var sawFinal = false

        init(source: ByteSource, key: SymmetricKey, header: Header) {
            self.source = source
            self.key = key
            self.noncePrefix = header.noncePrefix
            self.header = header.encoded
            self.chunkSize = Int(header.chunkSize)
        }

        /// The next chunk's plaintext, or nil once the final chunk has been consumed.
        func next() throws -> Data? {
            if sawFinal { return nil }
            let prefix = try source.read(5)
            guard prefix.count == 5 else {
                throw ArchiveError.truncated(prefix.isEmpty
                    ? "it ends where another block was promised"
                    : "a block header was cut short")
            }
            let length = HistoryArchive.readBE32(prefix, at: 0)
            let flag = prefix[prefix.startIndex + 4]
            guard flag == 0 || flag == 1 else {
                throw ArchiveError.damagedOrModified("a block's end marker is not 0 or 1")
            }
            guard length > 0, Int(length) <= chunkSize else {
                throw ArchiveError.damagedOrModified("a block declares an impossible length")
            }
            let want = Int(length) + 16
            let body = try source.read(want)
            guard body.count == want else {
                throw ArchiveError.truncated("a block is shorter than it declares")
            }
            index += 1
            var aad = header
            aad.append(HistoryArchive.be64(index))
            aad.append(flag)
            aad.append(HistoryArchive.be32(length))
            guard let nonce = try? AES.GCM.Nonce(data: noncePrefix + HistoryArchive.be64(index)),
                  let box = try? AES.GCM.SealedBox(nonce: nonce,
                                                   ciphertext: body.prefix(Int(length)),
                                                   tag: body.suffix(16)),
                  let plain = try? AES.GCM.open(box, using: key, authenticating: aad)
            else { throw ArchiveError.damagedOrModified("a block failed its integrity check") }
            if flag == 1 {
                sawFinal = true
                // Bytes appended after the final chunk are a refusal, not a curiosity.
                if try !source.read(1).isEmpty { throw ArchiveError.trailingBytes }
            }
            return plain
        }
    }

    // MARK: - The record stream

    enum RecordType: UInt8 {
        case manifest = 1
        case clip = 2
        case imageFeature = 3
        case dismissal = 4
        case payload = 5
        case pad = 6
        case end = 255
    }

    /// `u8 type ‖ u16BE nameLen ‖ name(UTF-8) ‖ u64BE bodyLen ‖ body`
    static func recordFrameOverhead(nameLength: Int) -> Int { 1 + 2 + nameLength + 8 }

    final class RecordWriter {
        let chunks: ChunkWriter
        init(chunks: ChunkWriter) { self.chunks = chunks }

        func write(_ type: RecordType, name: String, body: Data) throws {
            let nameBytes = Data(name.utf8)
            var head = Data(capacity: HistoryArchive.recordFrameOverhead(
                nameLength: nameBytes.count))
            head.append(type.rawValue)
            head.append(HistoryArchive.be16(UInt16(nameBytes.count)))
            head.append(nameBytes)
            head.append(HistoryArchive.be64(UInt64(body.count)))
            try chunks.append(head)
            if !body.isEmpty { try chunks.append(body) }
        }

        /// Pad so the final chunk is full, then the end record, then seal the last frame.
        func finishWithPadAndEnd() throws {
            let overhead = HistoryArchive.recordFrameOverhead(nameLength: 0) * 2
            let padLength = chunks.bytesToNextBoundary(afterAdding: overhead)
            try write(.pad, name: "", body: Data(repeating: 0, count: padLength))
            try write(.end, name: "", body: Data())
            try chunks.finish()
        }
    }

    struct RawRecord {
        let type: UInt8
        let name: String
        let body: Data
    }

    /// Byte stream over the chunk reader, so a record may straddle any number of chunks.
    final class RecordReader {
        private let chunks: ChunkReader
        private var buffer = Data()
        private var offset = 0
        init(chunks: ChunkReader) { self.chunks = chunks }

        private func read(_ count: Int) throws -> Data {
            guard count >= 0 else { throw ArchiveError.malformedRecord("a negative length") }
            while buffer.count - offset < count {
                guard let chunk = try chunks.next() else {
                    throw ArchiveError.truncated("the contents end before the final record")
                }
                if offset > 0 {
                    buffer = Data(buffer.dropFirst(offset))
                    offset = 0
                }
                buffer.append(chunk)
            }
            let base = buffer.startIndex + offset
            let out = buffer.subdata(in: base..<(base + count))
            offset += count
            if offset == buffer.count { buffer = Data(); offset = 0 }
            return out
        }

        func next() throws -> RawRecord {
            let type = try read(1)[0]
            let nameLength = Int(HistoryArchive.readBE16(try read(2), at: 0))
            let name = String(decoding: try read(nameLength), as: UTF8.self)
            let bodyLength = HistoryArchive.readBE64(try read(8), at: 0)
            // CHECKED BEFORE THE ALLOCATION. A hostile 2^63 here would otherwise be a
            // nine-exabyte `Data(count:)` and a dead process.
            guard bodyLength <= UInt64(HistoryArchive.maxRecordBody) else {
                throw ArchiveError.malformedRecord("a record claims an impossible size")
            }
            return RawRecord(type: type, name: name, body: try read(Int(bodyLength)))
        }
    }

    // MARK: - The summary / manifest model

    /// What the preview sheet renders — AFTER the passphrase, BEFORE the body.
    ///
    /// This is the ONLY description of the history in the file, it is sealed, and opening
    /// it is the passphrase check. Padded to exactly 1024 bytes so its length says nothing.
    struct Summary: Codable, Equatable {
        var format = "cliphoard-archive"
        var version = 1
        var appVersion: String
        var exportedAt: String
        var machineName: String
        var clipCount: Int
        var byKind: [String: Int]
        var pinnedCount: Int
        var oldestCreatedAt: Double
        var newestCreatedAt: Double
        var payloadCount: Int
        var payloadBytes: Int
        var imageFeatureCount: Int
        var dismissalCount: Int
        var embeddingsIncluded: Bool
        var imageFeaturesIncluded: Bool
        var skippedUnreadableClips: Int
        var skippedUnreadablePayloads: Int

        static func encoder() -> JSONEncoder {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return e
        }

        var json: Data { (try? Self.encoder().encode(self)) ?? Data() }

        /// JSON, NUL-padded to exactly 1024 bytes. If the machine name makes it overflow,
        /// the NAME is truncated — visibly, with an ellipsis — rather than the block grown.
        /// A variable-length block would leak its own length.
        func paddedPlaintext() throws -> Data {
            var copy = self
            var body = copy.json
            var name = machineName
            while body.count > HistoryArchive.summaryPlaintextLength, name.count > 1 {
                name = String(name.dropLast(2))
                copy.machineName = name + "…"
                body = copy.json
            }
            guard body.count <= HistoryArchive.summaryPlaintextLength else {
                throw ArchiveError.cannotWrite("the summary does not fit in its fixed block")
            }
            return body + Data(repeating: 0,
                               count: HistoryArchive.summaryPlaintextLength - body.count)
        }

        static func parse(padded: Data) throws -> Summary {
            var trimmed = padded
            while let last = trimmed.last, last == 0 { trimmed.removeLast() }
            guard let summary = try? JSONDecoder().decode(Summary.self, from: trimmed) else {
                throw ArchiveError.malformedRecord("the summary block did not parse")
            }
            return summary
        }
    }

    /// One clip, as exactly the sixteen columns `loadAllUnchecked` reads and `insert`
    /// writes — nothing more.
    ///
    /// `imageHash` is deliberately NOT here. It is in-memory only (never a column, never
    /// read by the loader, never written by the insert), so carrying it would be dead
    /// weight AND would make "every field survives the round trip" assert something the
    /// database itself does not preserve.
    ///
    /// `ocrText` uses key-absence for `nil`: absent = "never analysed", `""` = "analysed,
    /// deliberately withheld". That three-state distinction is why `Database` carries
    /// NULL-vs-empty rather than a separate marker column, and it has to survive the
    /// archive or a migrated Mac silently re-analyses screenshots whose recognised text
    /// the source Mac deliberately refused to store.
    struct Clip: Codable, Equatable {
        var id: String
        var kind: String
        var text: String
        var rtfB64: String?
        var payloadFile: String?
        var filePath: String?
        var colorHex: String?
        /// Raw `timeIntervalSinceReferenceDate` — what SQLite stores — so timestamps
        /// round-trip bit for bit with no formatter anywhere in the path.
        var createdAt: Double
        var lastUsedAt: Double
        var pinned: Bool
        var sourceApp: String?
        var useCount: Int
        var userTags: [String]
        /// The FULL raw integer, honouring `Database.insert`'s rule that a flag written by
        /// a newer version must survive a round trip untouched.
        var flags: Int
        var shape: String?
        var ocrText: String?
    }

    struct FeatureRecord: Codable, Equatable {
        var revision: Int
        var vectorB64: String
    }

    struct DismissalRecord: Codable, Equatable {
        var tag: String
    }

    /// Float32, little-endian — stated rather than assumed, so a future big-endian reader
    /// has a rule to follow instead of a memory layout to guess at.
    static func vectorBase64(_ vector: [Float]) -> String {
        var out = Data(capacity: vector.count * 4)
        for value in vector {
            var le = value.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        return out.base64EncodedString()
    }

    static func vector(fromBase64 s: String) -> [Float]? {
        guard let data = Data(base64Encoded: s), data.count % 4 == 0 else { return nil }
        var out = [Float]()
        out.reserveCapacity(data.count / 4)
        var i = data.startIndex
        while i < data.endIndex {
            let bits = UInt32(data[i]) | UInt32(data[i + 1]) << 8
                     | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
            out.append(Float(bitPattern: UInt32(littleEndian: bits)))
            i += 4
        }
        return out
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Opening a file's header + summary (Phase A, in one place)

    struct Opened {
        let header: Header
        let key: SymmetricKey
        let summary: Summary
        let source: ByteSource
    }

    /// Validate the header, derive the key, open the sealed summary. Nothing else is read.
    ///
    /// A WRONG PASSPHRASE DIES HERE, before any store is touched — and the message says
    /// "wrong passphrase OR damaged", because at this point those two really are
    /// indistinguishable. Every later failure says "damaged or modified" only, because by
    /// then the key has proven itself.
    static func open(source: ByteSource, passphrase: String) throws -> Opened {
        guard passphrase.count >= passphraseMinimumLength else {
            throw ArchiveError.passphraseTooShort(passphrase.count)
        }
        let rawHeader = try source.read(headerLength)
        let header = try Header.decode(rawHeader)
        guard let key = deriveKey(passphrase: passphrase, salt: header.kdfSalt,
                                  iterations: header.kdfIterations) else {
            throw ArchiveError.keyDerivationFailed
        }
        let sealed = try source.read(Int(header.summaryLen))
        guard sealed.count == Int(header.summaryLen) else {
            throw ArchiveError.truncated("the summary block is incomplete")
        }
        guard let nonce = try? AES.GCM.Nonce(data: header.noncePrefix + be64(0)),
              let box = try? AES.GCM.SealedBox(nonce: nonce,
                                               ciphertext: sealed.prefix(summaryPlaintextLength),
                                               tag: sealed.suffix(16)),
              let plain = try? AES.GCM.open(box, using: key,
                                            authenticating: Data(rawHeader.prefix(headerLength)))
        else { throw ArchiveError.wrongPassphraseOrDamaged }
        return Opened(header: header, key: key,
                      summary: try Summary.parse(padded: plain), source: source)
    }
}
