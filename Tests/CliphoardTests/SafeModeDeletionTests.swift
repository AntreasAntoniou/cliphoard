import XCTest
@testable import Cliphoard

/// TP-22: a frozen store must not delete.
///
/// Safe mode's own log promises "nothing will be deleted". That promise was false: the
/// history trim ran ahead of the write guard and was itself ungated, so a frozen store
/// would add a clip to memory, persist nothing, and still evict the oldest REAL clips —
/// removing their payload files and their rows. Deleting old data while storing none is
/// a straight loss, and it fires with no capture at all, because the history-limit
/// setter calls trim directly.
///
/// Two changes of mine opened it: freezing writes but not deletes turned a trade of
/// new-for-old into a deletion, and making the freeze unconditional on canary health made
/// that state far more reachable. Each was correct alone; together they were not.
@MainActor
final class SafeModeDeletionTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-mode-del-\(UUID().uuidString)")
    }

    /// Runs only when the store is genuinely frozen — which is the only state where the
    /// property is meaningful. Inverted coverage by necessity: on a healthy machine there
    /// is no safe mode to test, so it skips and says so.
    func testAFrozenStoreDeletesNothingWhenOverTheLimit() throws {
        let dir = tempDir()
        let store = ClipStore(directory: dir)
        try XCTSkipUnless(store.safeMode,
                          "store is healthy here, so there is no frozen state to exercise "
                          + "— this property only exists while safe mode is engaged")

        // Far below the number of clips we are about to add, so an ungated trim would
        // certainly fire.
        let previousLimit = store.historyLimit
        defer { store.historyLimit = previousLimit }

        for i in 0..<12 { store.add(ClipItem(kind: .text, text: "clip \(i)")) }
        let beforeCount = store.items.count

        // The setter calls trim() directly — this is the no-capture-required path.
        store.historyLimit = 3

        XCTAssertEqual(store.items.count, beforeCount,
                       "a frozen store evicted clips from memory; with the database write "
                       + "already blocked, that is deletion with nothing stored in return")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("ditto.sqlite").path)
            && store.items.isEmpty,
            "frozen store emptied itself")
    }

    /// The converse, so this file cannot pass by freezing everything: a HEALTHY store must
    /// still enforce its limit, or the guard has quietly disabled a real feature.
    func testAHealthyStoreStillEnforcesItsLimit() throws {
        let store = ClipStore(directory: tempDir())
        try XCTSkipIf(store.safeMode,
                      "store is frozen here (keychain unreachable), so normal trimming "
                      + "cannot be exercised")

        let previousLimit = store.historyLimit
        defer { store.historyLimit = previousLimit }

        for i in 0..<12 { store.add(ClipItem(kind: .text, text: "clip \(i)")) }
        store.historyLimit = 3

        XCTAssertLessThanOrEqual(store.items.filter { !$0.pinned }.count, 3,
                                 "a healthy store must still trim to its limit — the safe-mode "
                                 + "guard must not disable trimming outright")
    }

    /// The three user-facing destructive actions must REFUSE while frozen.
    ///
    /// They had no tests at all. Worse, `testClearUnpinned` was converted from failing to
    /// skipping in the very commit that changed its behaviour — the guard is intended, but
    /// converting the old assertion to a skip removed the only coverage without replacing
    /// it. This is the replacement, in the inverted form this file already uses.
    ///
    /// Safe mode is the state where every clip renders as `enc1:` gibberish, so it
    /// actively manufactures the motive to press Delete on data that is fully recoverable
    /// once the keychain is reachable again.
    func testFrozenStoreRefusesEveryDestructiveAction() throws {
        let store = ClipStore(directory: tempDir())
        try XCTSkipUnless(store.safeMode,
                          "store is healthy here, so there is no frozen state to exercise")

        for i in 0..<4 { store.add(ClipItem(kind: .text, text: "clip \(i)")) }
        let before = store.items.count
        XCTAssertGreaterThan(before, 0, "precondition: clips must be present in memory")

        store.delete(store.items[0])
        XCTAssertEqual(store.items.count, before,
                       "delete() removed a clip while frozen — it also unlinks the image "
                       + "payload, so this is permanent")

        store.clearUnpinned()
        XCTAssertEqual(store.items.count, before,
                       "clearUnpinned() emptied a frozen store — the largest blast radius "
                       + "in the app, on rows the process knows it cannot read")

        store.forgetImageUnderstanding()
        XCTAssertEqual(store.items.count, before,
                       "forgetImageUnderstanding() mutated a frozen store")
    }

    /// The converse, so the guards cannot pass by disabling the features outright.
    func testHealthyStoreStillDeletes() throws {
        let store = ClipStore(directory: tempDir())
        try XCTSkipIf(store.safeMode, "store is frozen here (keychain unreachable)")

        for i in 0..<3 { store.add(ClipItem(kind: .text, text: "clip \(i)")) }
        let before = store.items.count
        store.delete(store.items[0])
        XCTAssertEqual(store.items.count, before - 1,
                       "a healthy store must still delete — the safe-mode guard must not "
                       + "disable deletion outright")
    }
}
