import Foundation

/// Every pass that PERMANENTLY DESTROYS stored bytes.
///
/// Static functions on a caseless enum, deliberately: they have no `self`, so they
/// cannot reach `ClipStore.items` — the collapsed value that let an unreadable database
/// look like an empty one. The only history they can act on is the `CompleteHistory`
/// handed in, and the only way to obtain one is `Database.loadAllStatus` returning
/// `.complete`, which requires that every scan reached the end of its table AND that
/// the row count matched what the database itself reported.
///
/// This is the same move that fixed the keychain layer: `Crypto.readBlobStatus` returns
/// `.found`/`.absent`/`.unavailable` and `mayMintNewKey` accepts only `.absent`, so
/// minting a key over a live one is unrepresentable rather than merely discouraged. That
/// fix has held under fourteen consecutive rounds of adversarial review while every
/// positional guard in this codebase has been breached at least once. A guard is
/// invisible to code that does not contain it; a required argument of a type the caller
/// cannot construct is the first thing the compiler asks them about.
///
/// It is not airtight — nothing stops someone writing `for item in items` inside
/// `ClipStore` itself. It is a reduction in reachable surface, not a proof.
///
/// Do not add a function here that takes a bare `[ClipItem]`, and do not add one that
/// takes a `ClipStore`.
enum HistoryReaper {

    // MARK: - The decision core (pure, and therefore always testable)
    //
    // The refusals live in pure functions over plain values because the states that
    // matter are ones a healthy machine cannot be put into on demand — a dead handle, a
    // scan cut short, a directory that will not list. A rule that can only be tested in
    // its safe state is not a tested rule. It also means these run on a lid-closed
    // machine, where anything that constructs a ClipStore returns early in safe mode and
    // would pass for the wrong reason.

    /// Deleting more than half the payloads on disk is not housekeeping.
    ///
    /// This is the refusal that survives the case no count check can reach. A count
    /// that fails is now `.unavailable` and refuses earlier — but a `ditto.sqlite`
    /// truncated to zero bytes, or restored from a partial backup, opens cleanly,
    /// creates its tables, and reports a TRUTHFUL, authoritative count of zero. (Probed:
    /// zero-byte file → open rc 0, CREATE rc 0, COUNT rc 0, step ROW, count 0.) The read
    /// is complete and the history really is empty, while every payload PNG — possibly
    /// the last surviving copy of those images — is still on disk.
    ///
    /// Keying on "the item list is empty" would only delay the loss by one launch: copy
    /// a single text clip and the refusal stops firing. Keying on proportion survives
    /// that walk, and mirrors the existing safe-mode idiom exactly
    /// (`items.count >= 10 && unreadable * 2 > items.count`), so it is this codebase's
    /// own rule rather than an invented one.
    ///
    /// Accepted false positive, stated plainly: a small store (4 images, 6 strays)
    /// refuses and leaves 6 files on disk. That costs bytes, self-heals as the store
    /// grows, and is logged. The sweep's own contract calls itself best-effort
    /// housekeeping, so declining is within it. The alternative cost is every image the
    /// user has.
    static func isDisproportionate(deletable: Int, onDisk: Int) -> Bool {
        onDisk >= 10 && deletable * 2 > onDisk
    }

    /// The payload files a sweep is entitled to delete, or nil to delete NOTHING.
    ///
    /// `onDisk == nil` means the directory could not be ENUMERATED — which is not "there
    /// is nothing there", the same distinction one layer down in the filesystem.
    static func sweepDecision(onDisk: Set<String>?, referenced: Set<String>) -> Set<String>? {
        guard let onDisk else { return nil }
        // A clip "<uuid>.png" may have a sidecar thumbnail "<uuid>-thumb.png"
        // (ClipboardMonitor.writeThumbnail). Keep a thumbnail whose original is still
        // referenced — otherwise the sweep deletes every thumbnail on launch.
        func isLiveThumbnail(_ name: String) -> Bool {
            guard name.hasSuffix("-thumb.png") else { return false }
            return referenced.contains(String(name.dropLast("-thumb.png".count)) + ".png")
        }
        let deletable = onDisk.filter { !referenced.contains($0) && !isLiveThumbnail($0) }
        guard !isDisproportionate(deletable: deletable.count, onDisk: onDisk.count) else {
            return nil
        }
        return deletable
    }

    /// Image clips whose payload is genuinely gone, or nil to delete NOTHING.
    ///
    /// Decided from ONE successful directory listing rather than per-file
    /// `FileManager.fileExists`, which returns false for "not there" AND for "I could
    /// not stat it". That collapse needed no sqlite failure at all: one unreadable store
    /// directory — an unmounted volume, an ownership change, a `createDirectory` that
    /// silently failed — reported every payload missing and deleted every image row,
    /// while the sweep next door correctly declined to touch the files. Two launches to
    /// total loss with a perfectly healthy database.
    static func orphanDecision(onDisk: Set<String>?,
                               imagePayloadsByClip: [UUID: String]) -> Set<UUID>? {
        guard let onDisk else { return nil }
        let missing = Set(imagePayloadsByClip
            .filter { !onDisk.contains($0.value) }
            .map(\.key))
        // Same proportionality rule, same reason: an empty-but-listable directory facing
        // 200 image rows is the same catastrophe through a different door.
        guard !isDisproportionate(deletable: missing.count,
                                  onDisk: max(onDisk.count, imagePayloadsByClip.count))
        else { return nil }
        return missing
    }

    // MARK: - The passes (token-taking, used in production)

    /// Every "*.png" in `dir`, or nil when the directory could not be listed.
    static func payloadFilesOnDisk(in dir: URL) -> Set<String>? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        return Set(entries.filter { $0.pathExtension.lowercased() == "png" }
                          .map(\.lastPathComponent))
    }

    /// Delete unreferenced payload files. Returns how many were removed, or nil if the
    /// sweep declined — which is a normal, logged outcome, not an error.
    @discardableResult
    static func sweepOrphanPayloads(in dir: URL, history: Database.CompleteHistory) -> Int? {
        let onDisk = payloadFilesOnDisk(in: dir)
        guard let victims = sweepDecision(onDisk: onDisk,
                                          referenced: history.referencedPayloads) else {
            DebugLog.write("sweep: declined — "
                           + (onDisk == nil ? "payload directory unreadable"
                                            : "would delete most of the directory"))
            return nil
        }
        guard !victims.isEmpty else { return 0 }
        DebugLog.write("sweep: removing \(victims.count) unreferenced payload(s)")
        var removed = 0
        for name in victims {
            if (try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Image clips whose payload has genuinely vanished, or nil to delete nothing.
    static func orphanedImageRows(in dir: URL, history: Database.CompleteHistory) -> Set<UUID>? {
        let onDisk = payloadFilesOnDisk(in: dir)
        guard let dead = orphanDecision(onDisk: onDisk,
                                        imagePayloadsByClip: history.imagePayloadsByClip) else {
            DebugLog.write("orphan rows: declined — "
                           + (onDisk == nil ? "payload directory unreadable"
                                            : "would delete most of the image rows"))
            return nil
        }
        return dead
    }
}
