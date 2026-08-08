import Foundation

/// The passes that destroy stored bytes on the strength of a SCAN OF THE STORE.
///
/// Not every deleter in the app, and the difference is the point. These two infer their
/// victims from the ABSENCE of something — a payload not in a listing, a file not in a
/// row set — so a read that failed and a store that is empty look identical to them, and
/// that substitution is what cost 210 clips. They therefore take proof the read was whole.
///
/// The others act on a target the CALLER named: `Database.delete(id:)`/`delete(ids:)`,
/// `deleteUnpinned`, `deleteEmbeddings`, `deleteImageFeature`, `forgetAllImageUnderstanding`,
/// `ClipStore.trim`/`clearUnpinned`/`removePayload`, and `TagAudit --delete`. They cannot be
/// fooled into inventing victims because they invent none, and each is gated where its own
/// provenance question lives (safe mode, or the completeness guard in `archiveUnreadable`).
/// Do NOT give them a token: it would claim "this history was read whole" where the real
/// claim is "the caller asked for these ids", and a token meaning two things means neither.
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

    /// Deleting more than half the payloads is not housekeeping.
    ///
    /// TWO POPULATIONS, deliberately, and mixing them is how this rule quietly drifted.
    /// The FLOOR counts FILES; the RATIO counts PAYLOAD IDENTITIES. A thumbnail is a
    /// derivative, not a second image — and coverage is non-uniform BY CONSTRUCTION here,
    /// because `writeThumbnail` is best-effort and `removePayload` deletes a clip's thumb
    /// WITH its original. So live payloads mostly have sidecars and dead ones often do
    /// not, and a file-counted ratio slid anywhere between a third and two thirds:
    /// measured, 20 live-with-thumbs against 21 dead-bare deleted 21 of 41, over half.
    /// Sidecars cancel only when coverage is uniform, which is exactly the case that
    /// makes the bug invisible if you probe it.
    ///
    /// The floor keeps counting FILES on purpose. Counting payloads on both sides looks
    /// tidier and destroys a store: nine images with thumbs whose database truthfully
    /// reports zero — the flagship scenario of this whole effort — is 18 files but 9
    /// payloads, so a payload-counted floor falls below 10 and deletes all nine. Measured.
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
    static func isDisproportionate(deletablePayloads: Int, allPayloads: Int,
                                   onDiskFiles: Int) -> Bool {
        onDiskFiles >= 10 && deletablePayloads * 2 > allPayloads
    }

    /// The payload a file belongs to. A thumbnail is a DERIVATIVE of its original, not an
    /// image in its own right: "<uuid>-thumb.png" -> "<uuid>.png".
    static func payloadIdentity(of name: String) -> String {
        guard name.hasSuffix("-thumb.png") else { return name }
        return String(name.dropLast("-thumb.png".count)) + ".png"
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
        // The VICTIM SET is unchanged — only the population the proportion is taken over.
        guard !isDisproportionate(
            deletablePayloads: Set(deletable.map(Self.payloadIdentity)).count,
            allPayloads: Set(onDisk.map(Self.payloadIdentity)).count,
            onDiskFiles: onDisk.count) else { return nil }
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
        // The ratio drops the `max`, which inflated the denominator with sidecars and so
        // weakened the guard; the FLOOR keeps it, so the rule arms no less often than before.
        guard !isDisproportionate(deletablePayloads: missing.count,
                                  allPayloads: imagePayloadsByClip.count,
                                  onDiskFiles: max(onDisk.count, imagePayloadsByClip.count))
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
