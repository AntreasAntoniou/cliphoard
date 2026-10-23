import AppKit
import CryptoKit

/// Export and import, in terms of the app's own types — the only place `HistoryArchive`'s
/// bytes meet a `ClipItem`.
///
/// The split matters. Everything that can refuse a FILE lives in `HistoryArchive` and is
/// pure; everything that can refuse a STORE lives here. That is what lets the tamper and
/// truncation tests run without a keychain, and it is why the gates below read as a short
/// list rather than as a scatter of conditions through a stream loop.
@MainActor
enum HistoryArchiveIO {

    typealias ArchiveError = HistoryArchive.ArchiveError

    // MARK: - Reports

    struct ExportReport {
        var url: URL
        var summary: HistoryArchive.Summary
        var clipCount: Int
        var payloadCount: Int
        var imageFeatureCount: Int
        var dismissalCount: Int
        var byteCount: Int
        var skippedUnreadableClips: Int
        var skippedUnreadablePayloads: Int
        var seconds: Double
    }

    struct VerifyReport {
        var summary: HistoryArchive.Summary
        var clipCount: Int
        var payloadCount: Int
        var imageFeatureCount: Int
        var dismissalCount: Int
        var byKind: [String: Int]
        var bytesVerified: Int
        var seconds: Double
    }

    /// Everything the import has read and quarantined. The store has NOT been touched yet.
    struct Staged {
        var summary: HistoryArchive.Summary
        var clips: [ClipItem]
        var dismissals: [(tag: String, clipID: UUID)]
        var stagingDirectory: URL
        /// Payload (and thumbnail) file names sitting in `stagingDirectory`, ready to move.
        var stagedPayloads: [String]
        /// Payloads the destination already had. Content-addressed names make this exact
        /// and free — on a re-import of a 295 MB file this is the whole cost.
        var payloadsAlreadyPresent: Int
    }

    // MARK: - Gates

    /// The refusal that covers "this process cannot read its own history".
    ///
    /// `Crypto.ensureKeyResolved()` — the FUNCTION, not the stale flag. The flag is set as
    /// a side effect of resolving the key and the key resolves lazily, so every guard that
    /// read the flag ran before the thing that sets it.
    static func healthRefusal(safeMode: Bool) -> ArchiveError? {
        if safeMode { return .storeFrozen }
        if !Crypto.decryptionHealthy { return .storeFrozen }
        if Crypto.ensureKeyResolved() { return .storeFrozen }
        return nil
    }

    // MARK: - Export

    /// A save-panel grant covers the selected URL, not an invented sibling such as
    /// `history.cliphoard-partial`. Foundation supplies a writable replacement directory
    /// on the destination's volume, so the encrypted stream can stay private until complete.
    /// Call `cleanup` on every path; only ciphertext is ever written to this handle.
    final class ExportFile {
        let destination: URL
        let partialDirectory: URL
        let partial: URL
        let handle: FileHandle
        private(set) var recoveryURL: URL?

        init(destination: URL) throws {
            self.destination = destination
            let manager = FileManager.default
            partialDirectory = try manager.url(for: .itemReplacementDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: destination, create: true)
            partial = partialDirectory.appendingPathComponent("archive.partial")
            do {
                try manager.setAttributes([.posixPermissions: 0o700],
                                          ofItemAtPath: partialDirectory.path)
                guard manager.createFile(atPath: partial.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else {
                    throw ArchiveError.cannotWrite("the temporary file could not be created")
                }
                handle = try FileHandle(forWritingTo: partial)
            } catch {
                try? manager.removeItem(at: partialDirectory)
                throw error
            }
        }

        func cleanup() {
            try? handle.close()
            if let recoveryURL {
                let recovered = recoveryURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                let staging = partialDirectory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                // Foundation can relocate the ORIGINAL into our directory on a failed
                // replacement. Retain that directory instead of deleting the old backup.
                if recovered.starts(with: staging) { return }
            }
            try? FileManager.default.removeItem(at: partialDirectory)
        }

        func finish(replace: (URL, URL) throws -> Void = { original, replacement in
            _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement,
                                                       options: .usingNewMetadataOnly)
        }) throws {
            try handle.synchronize()
            try handle.close()

            var coordinationError: NSError?
            var result: Result<Void, Error>?
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing,
                                           error: &coordinationError) { selectedURL in
                result = Result {
                    let manager = FileManager.default
                    if manager.fileExists(atPath: selectedURL.path) {
                        // Never delete an old backup before its replacement succeeds. Keep
                        // the new file's private mode instead of inheriting weaker metadata.
                        try replace(selectedURL, partial)
                    } else {
                        // The OS placed the temporary file on this same volume, so this
                        // publishes the complete archive with a move, not a streamed copy.
                        try manager.moveItem(at: partial, to: selectedURL)
                    }
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else {
                throw ArchiveError.cannotWrite("the destination could not be coordinated")
            }
            do { try result.get() }
            catch {
                if let recovered = Self.originalItemLocation(in: error) {
                    recoveryURL = recovered
                    throw ArchiveError.exportRecoveryRequired(recovered)
                }
                throw error
            }
        }

        /// FileManager may wrap its safe-save error. Only an actual file URL supplied
        /// under the documented recovery key can suppress deletion of our staging tree.
        private static func originalItemLocation(in error: Error, depth: Int = 0) -> URL? {
            guard depth < 8 else { return nil }
            let cocoa = error as NSError
            if let url = cocoa.userInfo["NSFileOriginalItemLocationKey"] as? URL, url.isFileURL {
                return url
            }
            if let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? Error {
                return originalItemLocation(in: underlying, depth: depth + 1)
            }
            return nil
        }
    }

    /// Write the whole history to `url` as one encrypted file.
    ///
    /// The export takes `Database.CompleteHistory` AS A PARAMETER rather than a `Bool`,
    /// so the completeness guard is a type the next call site cannot construct rather than
    /// a check they can forget. This is the house rule (`ClipStore` stamps no one-shot
    /// marker without it) applied to a READER for the first time — and it is the most
    /// important guard here, because the user's next action after an export is very often
    /// to wipe the old Mac.
    ///
    /// It opens NO write handle on the store, takes NO transaction and stamps NO
    /// `UserDefaults` marker. That is what makes its undo `rm` rather than a promise, and
    /// `HistoryArchiveRoundTripTests.testTheExportWritesNothingToTheStore` asserts it.
    static func export(items: [ClipItem],
                       proof: Database.CompleteHistory,
                       directory: URL,
                       dismissals: [Database.UserTagDismissal],
                       safeMode: Bool,
                       to url: URL,
                       passphrase: String,
                       acknowledgingUnreadable: Bool,
                       progress: (Double, String) -> Void = { _, _ in })
        -> Result<ExportReport, ArchiveError> {

        let started = Date()
        // 1. The floor lives HERE, not only in the passphrase sheet: the CLI never sees
        //    the sheet, and a policy enforced at one of two entry points is the exact bug
        //    shape this codebase writes tests against.
        guard passphrase.count >= HistoryArchive.passphraseMinimumLength else {
            return .failure(.passphraseTooShort(passphrase.count))
        }
        if let refusal = healthRefusal(safeMode: safeMode) { return .failure(refusal) }
        // 2. PROOF. A short read and a smaller history are different facts.
        guard items.count == proof.storedCount else {
            return .failure(.historyNotProvenComplete)
        }

        // 3. SCREEN. `referenced` comes from the ITEMS, never from a directory scan: the
        //    real store also holds `models/` (385 MB of weights) and
        //    `unreadable-payloads-archive/`, and an export that enumerated the directory
        //    would sweep in the first and re-export the second.
        progress(0.02, "Checking what can be read…")
        let eligibleByText = items.filter { !Crypto.isSealed($0.text) }
        let skippedUnreadableClips = items.count - eligibleByText.count
        // SIZES, not bytes. Screening reads and opens every payload to prove it CAN be
        // read — and then lets it go. Keeping the plaintext here would hold the entire
        // 295 MB of pixels in memory for the whole export, which is exactly the property
        // the chunked writer exists to avoid; each payload is read a second time in step 7
        // and lives only as long as its own record. Two passes of I/O buys a flat memory
        // profile, and I/O is the cheap half.
        var payloadSizes: [String: Int] = [:]
        var unreadablePayloads: Set<String> = []
        for name in Set(eligibleByText.compactMap(\.payloadFile)).sorted() {
            autoreleasepool {
                guard let stored = try? Data(contentsOf: directory.appendingPathComponent(name)),
                      let opened = Crypto.open(stored), !Crypto.isSealed(opened) else {
                    unreadablePayloads.insert(name)
                    return
                }
                payloadSizes[name] = opened.count
            }
        }
        let eligible = eligibleByText.filter {
            guard let f = $0.payloadFile else { return true }
            return !unreadablePayloads.contains(f)
        }
        let skippedUnreadablePayloads = unreadablePayloads.count
        if (skippedUnreadableClips > 0 || skippedUnreadablePayloads > 0)
            && !acknowledgingUnreadable {
            return .failure(.unreadableContent(clips: skippedUnreadableClips,
                                               payloads: skippedUnreadablePayloads))
        }
        // Only the payloads a SURVIVING clip references get written.
        let referenced = Set(eligible.compactMap(\.payloadFile))
        payloadSizes = payloadSizes.filter { referenced.contains($0.key) }
        let payloadNames = payloadSizes.keys.sorted()

        // 4. KDF.
        progress(0.05, "Deriving the key from your passphrase…")
        guard let salt = HistoryArchive.randomBytes(HistoryArchive.kdfSaltLength),
              let noncePrefix = HistoryArchive.randomBytes(HistoryArchive.noncePrefixLength)
        else { return .failure(.randomnessUnavailable) }
        let iterations = HistoryArchive.calibratedIterations
        guard let fileKey = HistoryArchive.deriveKey(passphrase: passphrase, salt: salt,
                                                     iterations: iterations) else {
            return .failure(.keyDerivationFailed)
        }
        let header = HistoryArchive.Header(kdfIterations: iterations, kdfSalt: salt,
                                           noncePrefix: noncePrefix,
                                           chunkSize: HistoryArchive.defaultChunkSize)

        let features = eligible.compactMap { item -> (String, HistoryArchive.FeatureRecord)? in
            guard let fp = item.imageFeature, !fp.vector.isEmpty else { return nil }
            return (item.id.uuidString,
                    HistoryArchive.FeatureRecord(revision: fp.revision,
                                                 vectorB64: HistoryArchive.vectorBase64(fp.vector)))
        }
        let summary = makeSummary(clips: eligible,
                                  payloadSizes: payloadSizes,
                                  imageFeatureCount: features.count,
                                  dismissalCount: dismissals.count,
                                  skippedUnreadableClips: skippedUnreadableClips,
                                  skippedUnreadablePayloads: skippedUnreadablePayloads)

        // 5. OPEN encrypted staging outside the selected file's parent. A Save panel
        //    does not grant access to arbitrary siblings of the selected destination.
        let file: ExportFile
        do { file = try ExportFile(destination: url) }
        catch {
            return .failure(.cannotWrite("the file could not be created"))
        }
        defer { file.cleanup() }
        let handle = file.handle
        var wrote = 0

        do {
            // 6. header ‖ sealed summary.
            let headerBytes = header.encoded
            try handle.write(contentsOf: headerBytes)
            let padded = try summary.paddedPlaintext()
            let nonce = try AES.GCM.Nonce(data: noncePrefix + HistoryArchive.be64(0))
            let sealedSummary = try AES.GCM.seal(padded, using: fileKey, nonce: nonce,
                                                 authenticating: headerBytes)
            try handle.write(contentsOf: sealedSummary.ciphertext + sealedSummary.tag)
            wrote = headerBytes.count + sealedSummary.ciphertext.count + sealedSummary.tag.count

            // 7. STREAM the body.
            let chunks = HistoryArchive.ChunkWriter(
                key: fileKey, noncePrefix: noncePrefix, header: headerBytes,
                chunkSize: Int(header.chunkSize),
                sink: { frame in
                    try handle.write(contentsOf: frame)
                    wrote += frame.count
                })
            let records = HistoryArchive.RecordWriter(chunks: chunks)

            try records.write(.manifest, name: "manifest.json", body: summary.json)
            let encoder = HistoryArchive.Summary.encoder()
            for (n, item) in eligible.enumerated() {
                try autoreleasepool {
                    try records.write(.clip, name: item.id.uuidString,
                                      body: try encoder.encode(archiveClip(item)))
                }
                if n % 256 == 0 {
                    progress(0.05 + 0.15 * Double(n) / Double(max(1, eligible.count)),
                             "Writing clips… \(n)/\(eligible.count)")
                }
            }
            for (id, feature) in features {
                try records.write(.imageFeature, name: id, body: try encoder.encode(feature))
            }
            for dismissal in dismissals {
                try records.write(.dismissal, name: dismissal.clipID.uuidString,
                                  body: try encoder.encode(
                                      HistoryArchive.DismissalRecord(tag: dismissal.tag)))
            }
            // ONE payload in memory at a time. Re-read and re-opened here rather than
            // carried from the screening pass above, so peak memory is a chunk plus the
            // single largest image rather than the whole of the history's pixels.
            for (n, name) in payloadNames.enumerated() {
                try autoreleasepool {
                    guard let stored = try? Data(contentsOf: directory.appendingPathComponent(name)),
                          let png = Crypto.open(stored), !Crypto.isSealed(png) else {
                        // It opened a moment ago and does not now. Refuse rather than write
                        // a file that claims an image it does not contain.
                        throw ArchiveError.cannotRead("\(name) became unreadable mid-export")
                    }
                    try records.write(.payload, name: name, body: png)
                }
                progress(0.2 + 0.75 * Double(n + 1) / Double(max(1, payloadNames.count)),
                         "Writing images… \(n + 1)/\(payloadNames.count)")
            }
            try records.finishWithPadAndEnd()

        } catch let error as ArchiveError {
            return .failure(error)
        } catch {
            return .failure(.cannotWrite("\(error.localizedDescription)"))
        }

        // 8-9. fsync, close and install the complete 0600 archive. An existing backup
        //      remains in place until the coordinated replacement succeeds.
        do { try file.finish() }
        catch let error as ArchiveError { return .failure(error) }
        catch {
            return .failure(.cannotWrite("the finished file could not be put in place"))
        }
        progress(1.0, "Done.")
        return .success(ExportReport(
            url: url, summary: summary, clipCount: eligible.count,
            payloadCount: payloadNames.count, imageFeatureCount: features.count,
            dismissalCount: dismissals.count, byteCount: wrote,
            skippedUnreadableClips: skippedUnreadableClips,
            skippedUnreadablePayloads: skippedUnreadablePayloads,
            seconds: Date().timeIntervalSince(started)))
    }

    private static func makeSummary(clips: [ClipItem],
                                    payloadSizes: [String: Int],
                                    imageFeatureCount: Int,
                                    dismissalCount: Int,
                                    skippedUnreadableClips: Int,
                                    skippedUnreadablePayloads: Int) -> HistoryArchive.Summary {
        var byKind: [String: Int] = [:]
        for item in clips { byKind[item.kind.rawValue, default: 0] += 1 }
        let created = clips.map(\.createdAt.timeIntervalSinceReferenceDate)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return HistoryArchive.Summary(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? "1.0.1",
            exportedAt: formatter.string(from: Date()),
            machineName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            clipCount: clips.count,
            byKind: byKind,
            pinnedCount: clips.filter(\.pinned).count,
            oldestCreatedAt: created.min() ?? 0,
            newestCreatedAt: created.max() ?? 0,
            payloadCount: payloadSizes.count,
            payloadBytes: payloadSizes.values.reduce(0, +),
            imageFeatureCount: imageFeatureCount,
            dismissalCount: dismissalCount,
            // Recomputed on the destination: 71% of this database is embeddings across
            // five signatures of which the destination uses one, and `reindexStale()`
            // plus the `needsCLIPVector` arm already cover both halves with progress UI.
            embeddingsIncluded: false,
            // Carried, because they are NOT recomputable after import: the only writer of
            // `imageFeature` runs behind `needsImageUnderstanding`, which is false forever
            // once `ocrText` is non-nil — and a faithful import must carry `ocrText`.
            imageFeaturesIncluded: true,
            skippedUnreadableClips: skippedUnreadableClips,
            skippedUnreadablePayloads: skippedUnreadablePayloads)
    }

    static func archiveClip(_ item: ClipItem) -> HistoryArchive.Clip {
        HistoryArchive.Clip(
            id: item.id.uuidString,
            kind: item.kind.rawValue,
            text: item.text,
            rtfB64: item.rtf?.base64EncodedString(),
            payloadFile: item.payloadFile,
            filePath: item.filePath,
            colorHex: item.colorHex,
            createdAt: item.createdAt.timeIntervalSinceReferenceDate,
            lastUsedAt: item.lastUsedAt.timeIntervalSinceReferenceDate,
            pinned: item.pinned,
            sourceApp: item.sourceApp,
            useCount: item.useCount,
            userTags: item.userTags,
            flags: item.flags.rawValue,
            shape: item.shape,
            ocrText: item.ocrText)
    }

    static func clipItem(from clip: HistoryArchive.Clip) -> ClipItem? {
        guard let id = UUID(uuidString: clip.id) else { return nil }
        return ClipItem(id: id,
                        kind: ClipKind(rawValue: clip.kind) ?? .text,
                        text: clip.text,
                        rtf: clip.rtfB64.flatMap { Data(base64Encoded: $0) },
                        payloadFile: clip.payloadFile,
                        filePath: clip.filePath,
                        colorHex: clip.colorHex,
                        createdAt: Date(timeIntervalSinceReferenceDate: clip.createdAt),
                        lastUsedAt: Date(timeIntervalSinceReferenceDate: clip.lastUsedAt),
                        pinned: clip.pinned,
                        sourceApp: clip.sourceApp,
                        useCount: clip.useCount,
                        userTags: clip.userTags,
                        flags: ClipFlags(rawValue: clip.flags),
                        shape: clip.shape,
                        ocrText: clip.ocrText)
    }

    // MARK: - Import, Phase A: verify. Nothing is touched.

    /// Header, key, sealed summary. The wrong passphrase dies here.
    static func preview(url: URL, passphrase: String) -> Result<HistoryArchive.Summary, ArchiveError> {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.cannotRead("it could not be opened"))
        }
        defer { try? handle.close() }
        do {
            let opened = try HistoryArchive.open(
                source: HistoryArchive.FileByteSource(handle), passphrase: passphrase)
            return .success(opened.summary)
        } catch let error as ArchiveError {
            return .failure(error)
        } catch {
            return .failure(.cannotRead("\(error.localizedDescription)"))
        }
    }

    /// `--dry-run`: verify EVERY chunk's tag to EOF and tally what would be imported,
    /// writing nothing anywhere. This is the verifier's tool.
    static func verify(url: URL, passphrase: String,
                       progress: (Double, String) -> Void = { _, _ in })
        -> Result<VerifyReport, ArchiveError> {
        let started = Date()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.cannotRead("it could not be opened"))
        }
        defer { try? handle.close() }
        do {
            let opened = try HistoryArchive.open(
                source: HistoryArchive.FileByteSource(handle), passphrase: passphrase)
            let reader = HistoryArchive.RecordReader(
                chunks: HistoryArchive.ChunkReader(source: opened.source, key: opened.key,
                                                   header: opened.header))
            var clips = 0, payloads = 0, features = 0, dismissals = 0, bytes = 0
            var byKind: [String: Int] = [:]
            let decoder = JSONDecoder()
            var finished = false
            // EVERY record body goes through its own autorelease pool. `Data` and
            // `JSONDecoder` both hand back autoreleased Foundation objects, and this loop
            // runs thousands of times with no run loop under it to drain them — measured:
            // without the pool, verifying a 261 MB archive grew resident memory by 334 MB,
            // which is indistinguishable from "the reader buffered the whole file" and is
            // exactly the claim §12 is meant to falsify.
            while !finished {
                try autoreleasepool {
                    let record = try reader.next()
                    bytes += record.body.count
                    switch HistoryArchive.RecordType(rawValue: record.type) {
                    case .manifest:
                        let manifest = try decoder.decode(HistoryArchive.Summary.self,
                                                          from: record.body)
                        if manifest != opened.summary {
                            throw ArchiveError.manifestDisagreesWithSummary(
                                "the contents list does not match the summary")
                        }
                    case .clip:
                        let clip = try decoder.decode(HistoryArchive.Clip.self, from: record.body)
                        clips += 1
                        byKind[clip.kind, default: 0] += 1
                    case .imageFeature: features += 1
                    case .dismissal: dismissals += 1
                    case .payload:
                        guard HistoryArchive.sha256Hex(record.body) + ".png" == record.name else {
                            throw ArchiveError.payloadHashMismatch(record.name)
                        }
                        payloads += 1
                        progress(0.5, "Checking images… \(payloads)")
                    case .pad: break
                    case .end: finished = true
                    case .none: throw ArchiveError.unknownRecordType(record.type)
                    }
                }
            }
            return .success(VerifyReport(summary: opened.summary, clipCount: clips,
                                         payloadCount: payloads, imageFeatureCount: features,
                                         dismissalCount: dismissals, byKind: byKind,
                                         bytesVerified: bytes,
                                         seconds: Date().timeIntervalSince(started)))
        } catch let error as ArchiveError {
            return .failure(error)
        } catch {
            return .failure(.malformedRecord("\(error.localizedDescription)"))
        }
    }

    // MARK: - Import, Phase B: stream into quarantine. The store is still untouched.

    /// Read the whole file into `<store>/.import-<uuid>/`, verifying every tag and every
    /// content hash on the way.
    ///
    /// ANY failure — a bad tag, a bad sequence, EOF without the final flag, trailing bytes,
    /// a bad hash, unparsable JSON, a dangling payload reference — deletes the staging
    /// directory and aborts. THE STORE HAS NOT BEEN TOUCHED.
    static func stage(url: URL, passphrase: String, into directory: URL,
                      safeMode: Bool, storageComplete: Bool, hasProof: Bool,
                      progress: (Double, String) -> Void = { _, _ in })
        -> Result<Staged, ArchiveError> {

        guard passphrase.count >= HistoryArchive.passphraseMinimumLength else {
            return .failure(.passphraseTooShort(passphrase.count))
        }
        if let refusal = healthRefusal(safeMode: safeMode) { return .failure(refusal) }
        // The merge's "skip if the id is already here" is computed from the LOADED id set.
        // A short read makes that set a PREFIX, so merging into an incompletely-read store
        // duplicates everything it failed to load.
        guard storageComplete, hasProof else { return .failure(.historyNotProvenComplete) }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.cannotRead("it could not be opened"))
        }
        let staging = directory.appendingPathComponent(".import-\(UUID().uuidString)",
                                                       isDirectory: true)
        func abort(_ error: ArchiveError) -> Result<Staged, ArchiveError> {
            try? handle.close()
            try? FileManager.default.removeItem(at: staging)
            return .failure(error)
        }
        guard (try? FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])) != nil else {
            try? handle.close()
            return .failure(.cannotWrite("a staging folder could not be created"))
        }
        defer { try? handle.close() }

        do {
            let opened = try HistoryArchive.open(
                source: HistoryArchive.FileByteSource(handle), passphrase: passphrase)
            let reader = HistoryArchive.RecordReader(
                chunks: HistoryArchive.ChunkReader(source: opened.source, key: opened.key,
                                                   header: opened.header))
            var clips: [HistoryArchive.Clip] = []
            var features: [String: (revision: Int, vector: [Float])] = [:]
            var dismissals: [(tag: String, clipID: UUID)] = []
            var staged: [String] = []
            var alreadyPresent = 0
            var onDisk = Set<String>()
            let decoder = JSONDecoder()

            var finished = false
            while !finished {
                try autoreleasepool {
                let record = try reader.next()
                switch HistoryArchive.RecordType(rawValue: record.type) {
                case .manifest:
                    let manifest = try decoder.decode(HistoryArchive.Summary.self,
                                                      from: record.body)
                    guard manifest == opened.summary else {
                        throw ArchiveError.manifestDisagreesWithSummary(
                            "the contents list does not match the summary")
                    }
                case .clip:
                    clips.append(try decoder.decode(HistoryArchive.Clip.self, from: record.body))
                    if clips.count % 512 == 0 {
                        progress(0.1, "Reading clips… \(clips.count)")
                    }
                case .imageFeature:
                    let f = try decoder.decode(HistoryArchive.FeatureRecord.self,
                                               from: record.body)
                    guard let vector = HistoryArchive.vector(fromBase64: f.vectorB64) else {
                        throw ArchiveError.malformedRecord("an image print did not decode")
                    }
                    features[record.name] = (revision: f.revision, vector: vector)
                case .dismissal:
                    let d = try decoder.decode(HistoryArchive.DismissalRecord.self,
                                               from: record.body)
                    if let id = UUID(uuidString: record.name) {
                        dismissals.append((tag: d.tag, clipID: id))
                    }
                case .payload:
                    guard HistoryArchive.sha256Hex(record.body) + ".png" == record.name else {
                        throw ArchiveError.payloadHashMismatch(record.name)
                    }
                    onDisk.insert(record.name)
                    let destination = directory.appendingPathComponent(record.name)
                    guard !FileManager.default.fileExists(atPath: destination.path) else {
                        // Content-addressed, therefore byte-identical by construction.
                        alreadyPresent += 1
                        return
                    }
                    // `sealStrict`, NOT `seal`: under an ephemeral key an optimistic seal
                    // writes bytes nobody can open tomorrow. Refusing is the only honest
                    // answer, and it is the property `Database.insert` already relies on.
                    guard let sealed = Crypto.sealStrict(record.body) else {
                        throw ArchiveError.storeFrozen
                    }
                    let target = staging.appendingPathComponent(record.name)
                    try sealed.write(to: target, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                           ofItemAtPath: target.path)
                    staged.append(record.name)
                    // Regenerated rather than carried: 22.6 MB saved, pure derivative, and
                    // only 94 of 654 payloads have one on the source machine today — so
                    // the destination ends up strictly better off than the source.
                    let stem = (record.name as NSString).deletingPathExtension
                    ClipboardMonitor.writeThumbnail(
                        from: record.body,
                        to: staging.appendingPathComponent("\(stem)-thumb.png"))
                    if staged.count % 32 == 0 {
                        progress(0.5, "Reading images… \(staged.count)")
                    }
                case .pad: break
                case .end: finished = true
                case .none: throw ArchiveError.unknownRecordType(record.type)
                }
                }   // autoreleasepool — see `verify`; without it a 261 MB import grows
                    // resident memory by the size of the file.
            }

            // Every clip's payload must be present — in the store already, or staged.
            // This recovers, as an explicit check, the guarantee that "blobs before rows"
            // ordering would have given, without giving up the ability to skip payloads the
            // destination already holds.
            for clip in clips {
                guard let name = clip.payloadFile else { continue }
                if onDisk.contains(name) { continue }
                guard FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(name).path) else {
                    throw ArchiveError.danglingPayloadReference(name)
                }
            }

            var items: [ClipItem] = []
            items.reserveCapacity(clips.count)
            for clip in clips {
                guard let item = clipItem(from: clip) else {
                    throw ArchiveError.malformedRecord("a clip has no usable id")
                }
                // Set here so `Database.insert`'s existing write-through carries the print
                // into the SAME transaction as the row. Zero extra code in the committer.
                if let fp = features[clip.id], !fp.vector.isEmpty { item.imageFeature = fp }
                items.append(item)
            }
            return .success(Staged(summary: opened.summary, clips: items,
                                   dismissals: dismissals, stagingDirectory: staging,
                                   stagedPayloads: staged,
                                   payloadsAlreadyPresent: alreadyPresent))
        } catch let error as ArchiveError {
            return abort(error)
        } catch {
            return abort(.malformedRecord("\(error.localizedDescription)"))
        }
    }

    static func discard(_ staged: Staged) {
        try? FileManager.default.removeItem(at: staged.stagingDirectory)
    }
}
