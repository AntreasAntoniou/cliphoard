import XCTest
import AppKit
@testable import Cliphoard

/// One test per gate, each in both directions: FREE gets the gated behaviour, PRO gets the
/// whole thing. A gate asserted only in the free direction passes just as well against a
/// build where the feature was removed altogether, which is the failure this file is shaped
/// to avoid.
///
/// Every gate takes its `Entitlement` as an ARGUMENT — the `HistoryReaper` idiom — and that
/// is what makes this file possible at all. The private signing key lives outside the repo;
/// if the gates read `Licence.current` internally, a Pro assertion would need a signed key on
/// the machine, and a test keyed to one machine is not a test. `LicenceTests` already covers
/// the signature itself and skips honestly where the maintainer's sample key is absent.
///
/// THE ONE PROPERTY THAT OUTRANKS EVERY OTHER HERE: a paywall may withhold a capability and
/// may never destroy data. `testALicenceChangeNeverDeletesAClipAndFreeMayKeepEverything` is the assertion that
/// matters most in this file; if it ever goes red, the gate is worse than no gate.
@MainActor
final class LicenceGateTests: XCTestCase {

    private let pro = Entitlement.pro(orderID: "gate-tests", issued: Date(timeIntervalSince1970: 1))
    private let free = Entitlement.free(reason: nil)

    private func tempStore() -> ClipStore {
        ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoGate-\(UUID().uuidString)"))
    }

    // MARK: - Gate 1 · the search-mode picker

    func testGate1FreeCannotSelectImageSearchAndProCan() {
        let freeModes = SearchMode.available(free)
        XCTAssertFalse(freeModes.contains(.image),
                       "Image search is the demo and the thing being sold; a free build must "
                       + "not be able to select it")
        for mode in [SearchMode.exact, .tag, .neural, .smart] {
            XCTAssertTrue(freeModes.contains(mode),
                          "\(mode.rawValue) is FREE — semantic TEXT search stays in the free "
                          + "build (the models are the author's own and MIT on HuggingFace, so "
                          + "gating them would be a paywall in front of an open door)")
        }
        XCTAssertEqual(SearchMode.available(pro), SearchMode.allCases,
                       "Pro gets every mode, in the declared order")
    }

    /// A key removed while Image mode was selected must not leave the app opening in a mode
    /// that can only return nothing. The selection is corrected at launch; the user's CLIPS
    /// are not touched, because a mode is a preference and a clip is data.
    func testGate1APersistedImageModeIsCorrectedAtLaunchForAFreeBuild() throws {
        try skipIfKeychainUnreachable()
        let saved = UserDefaults.standard.string(forKey: "searchMode")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "searchMode") }
            else { UserDefaults.standard.removeObject(forKey: "searchMode") }
        }
        DeepSearch.mode = .image
        let store = tempStore()
        store.entitlement = free
        let settings = AppSettings(store: store)
        XCTAssertNotEqual(settings.searchMode, .image,
                          "a free build opened in Image mode — selected, unable to run, and "
                          + "able to return only an empty list")
        XCTAssertNotEqual(DeepSearch.mode, .image,
                          "the correction was not written through, so the next launch reads "
                          + "`.image` back and nothing was actually fixed")

        // And it is NOT corrected for someone entitled to it.
        DeepSearch.mode = .image
        let proStore = tempStore()
        proStore.entitlement = pro
        XCTAssertEqual(AppSettings(store: proStore).searchMode, .image,
                       "Pro's own selection was overwritten")
    }

    // MARK: - Gate 2 · reading text in images, and the towers behind it

    func testGate2FreeRefusesToEnableImageUnderstandingAndProAccepts() {
        let saved = UserDefaults.standard.object(forKey: "imageUnderstandingEnabled")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "imageUnderstandingEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "imageUnderstandingEnabled") }
        }

        ClipStore.setImageUnderstanding(true, entitlement: free)
        XCTAssertFalse(ClipStore.imageUnderstandingEnabled,
                       "the setter must REFUSE true for a free build — otherwise the stored "
                       + "preference claims a capability this build will not perform")
        XCTAssertFalse(ClipStore.imageUnderstandingAllowed(free))

        ClipStore.setImageUnderstanding(true, entitlement: pro)
        XCTAssertTrue(ClipStore.imageUnderstandingEnabled, "Pro may turn it on")
        XCTAssertTrue(ClipStore.imageUnderstandingAllowed(pro))

        // The opt-out still works for a paying user: Pro buys the capability, not an
        // obligation to run Vision over your screenshots.
        ClipStore.setImageUnderstanding(false, entitlement: pro)
        XCTAssertFalse(ClipStore.imageUnderstandingAllowed(pro))
    }

    /// The DEFAULT matters more than the setter here. `imageUnderstandingEnabled` defaults to
    /// ON for an untouched install, so a gate on the setter alone would leave every fresh free
    /// install reading text out of screenshots — a paid row, performed for free, by default.
    func testGate2AFreshFreeInstallIsNotAllowedImageUnderstanding() {
        let saved = UserDefaults.standard.object(forKey: "imageUnderstandingEnabled")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "imageUnderstandingEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "imageUnderstandingEnabled") }
        }
        UserDefaults.standard.removeObject(forKey: "imageUnderstandingEnabled")   // untouched
        XCTAssertTrue(ClipStore.imageUnderstandingEnabled, "precondition: the preference is on")
        XCTAssertFalse(ClipStore.imageUnderstandingAllowed(free),
                       "an untouched FREE install must still not read text in images")
        XCTAssertTrue(ClipStore.imageUnderstandingAllowed(pro))
    }

    /// A free build never loads a tower. Not "loads it and refuses to search": 33 MB of
    /// OpenVision is never mapped, so the paid feature costs a free user no memory and no
    /// launch time. Asserted through the seam the UI itself reads.
    func testGate2FreeNeverLoadsACLIPTower() throws {
        try skipIfKeychainUnreachable()
        let store = tempStore()
        store.entitlement = free
        XCTAssertNil(store.clipEmbedder,
                     "a free build loaded the CLIP towers. The gate is not just about "
                     + "refusing results — it is about never paying for the model.")
        XCTAssertTrue(store.imagesMatching("anything").isEmpty)
        XCTAssertTrue(store.imagesSimilar(toReferenceImage: Data([0x89, 0x50])).isEmpty)
    }

    // MARK: - The history limit is free

    func testEveryKeepRowIsFree() throws {
        try skipIfKeychainUnreachable()
        let store = tempStore()
        try XCTSkipIf(store.safeMode, "frozen store here")
        let savedLimit = UserDefaults.standard.object(forKey: "historyLimit")
        defer {
            if let savedLimit { UserDefaults.standard.set(savedLimit, forKey: "historyLimit") }
            else { UserDefaults.standard.removeObject(forKey: "historyLimit") }
        }
        store.entitlement = free
        for n in [100, 200, 500, 1000, 5000, 0] {
            store.historyLimit = n
            XCTAssertEqual(store.historyLimit, n, "a free build's Keep row \(n) was altered — "
                           + "the history limit is not part of the paid split")
        }
    }

    /// THE ONE THAT MATTERS. A licence change — either way — must never destroy a clip, and a
    /// free build may keep everything.
    ///
    /// The hoard is 600: above the OLD 500 ceiling, so a reintroduced clamp — at write time or
    /// as a use-time check in `trim()` — bites. (A first version of the ancestor of this test
    /// used 12 clips and was structurally incapable of failing; a blind verifier proved it.)
    func testALicenceChangeNeverDeletesAClipAndFreeMayKeepEverything() throws {
        try skipIfKeychainUnreachable()
        let store = tempStore()
        try XCTSkipIf(store.safeMode, "frozen store here — it refuses to persist, correctly")

        let savedLimit = UserDefaults.standard.object(forKey: "historyLimit")
        defer {
            if let savedLimit { UserDefaults.standard.set(savedLimit, forKey: "historyLimit") }
            else { UserDefaults.standard.removeObject(forKey: "historyLimit") }
        }

        let hoardSize = 600
        store.entitlement = free
        store.historyLimit = 0
        XCTAssertEqual(store.historyLimit, 0, "a free build may keep everything")
        for i in 0..<hoardSize { store.add(ClipItem(kind: .text, text: "clip \(i) — \(UUID())")) }
        XCTAssertEqual(store.items.count, hoardSize, "a free build with Unlimited was trimmed")
        store.add(ClipItem(kind: .text, text: "a capture under free"))
        XCTAssertEqual(store.items.count, hoardSize + 1, "a capture under free + Unlimited trimmed")

        store.entitlement = pro
        XCTAssertEqual(store.items.count, hoardSize + 1, "gaining Pro deleted clips")
        store.entitlement = free
        XCTAssertEqual(store.items.count, hoardSize + 1,
                       "losing Pro DELETED \(hoardSize + 1 - store.items.count) clip(s). A paywall "
                       + "may withhold a capability; it may never destroy data the user already has.")
        XCTAssertEqual(store.historyLimit, 0, "a licence change rewrote the stored limit")
        store.add(ClipItem(kind: .text, text: "after the downgrade"))
        XCTAssertEqual(store.items.count, hoardSize + 2,
                       "the first capture after a licence change trimmed the history")
    }

    // MARK: - The importers are free

    /// Every importer previews AND commits for everyone. The preview stays the SAFETY step —
    /// nine of the ten adapters have never been run against real data — and the commit is not
    /// entitlement-aware in either direction.
    func testEveryImporterIsFreeFreePreviewsAndCommits() throws {
        try skipIfKeychainUnreachable()
        let store = tempStore()
        try XCTSkipIf(store.safeMode, "frozen store here")
        guard let maccy = ClipImporters.all.first(where: { $0.id == "maccy" }),
              maccy.read != nil else {
            throw XCTSkip("no Maccy adapter in this build — nothing to check")
        }
        let savedLimit = UserDefaults.standard.object(forKey: "historyLimit")
        defer {
            if let savedLimit { UserDefaults.standard.set(savedLimit, forKey: "historyLimit") }
            else { UserDefaults.standard.removeObject(forKey: "historyLimit") }
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoGateImport-\(UUID().uuidString)", isDirectory: true)
        let path = try MaccyFixture.write(3, to: dir)
        let model = ImportModel()
        let candidate = ImportModel.Candidate(source: maccy, path: path)

        store.entitlement = free
        store.historyLimit = 0
        model.dryRun(candidate, store: store)
        XCTAssertEqual(store.items.count, 0, "a preview must write nothing, ever")
        XCTAssertEqual(model.preview?.total, 3,
                       "precondition: the fixture is read — an empty fixture could not see a commit")
        model.commit(candidate, store: store)
        XCTAssertEqual(store.items.count, 3, "a FREE build's import wrote nothing")
        XCTAssertEqual(model.result?.contains("Pro"), false, model.result ?? "")

        let proStore = tempStore()
        try XCTSkipIf(proStore.safeMode, "frozen store here")
        proStore.entitlement = pro
        proStore.historyLimit = 0
        let proModel = ImportModel()
        proModel.commit(candidate, store: proStore)
        XCTAssertEqual(proStore.items.count, 3, "Pro must reach the same writer")
    }

    // MARK: - Gate 5 · the Touch ID vault is NOT BUILT

    /// Gate 5 is the one with no code, and this is the test that keeps it that way.
    ///
    /// The site and PRIVACY.md say the vault is "coming, not yet built". A half-built
    /// `LAContext` call sitting in `Sources` would make that sentence false in the direction
    /// that matters — a security promise the user believes and the code does not keep — and
    /// it is exactly the drift a paid roadmap invites. If someone builds it, this test is the
    /// prompt to update the copy in the same commit.
    func testGate5TheTouchIDVaultIsNotBuiltAnywhere() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var offenders: [String] = []
        // `while let … where` would STOP at the first non-.swift entry rather than skip it,
        // which would quietly scan a fraction of the tree and pass for the wrong reason.
        for case let url as URL in FileManager.default
                .enumerator(at: sources, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for needle in ["LocalAuthentication", "LAContext", "evaluatePolicy",
                           "deviceOwnerAuthentication"] where code.contains(needle) {
                offenders.append("\(url.lastPathComponent): \(needle)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "the Touch ID vault is advertised as COMING and unbuilt, but \(offenders) "
                      + "exists. Either it shipped — in which case the site, PRIVACY.md and "
                      + "the pricing table must stop saying 'coming' in the same commit — or "
                      + "it is half-built, which is the worse of the two.")
    }

    // MARK: - Gate 6 · the Settings section

    /// The section is a view, so what is asserted is that the four things it must offer are
    /// wired to real symbols, in the right place in the stack. A key field with no Verify, or
    /// a Buy button pointing at a literal URL that drifts from `Licence.buyURL`, are the two
    /// ways this silently rots.
    func testGate6TheProSectionOffersKeyVerifyOrderBuyAndRemove() throws {
        let settings = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Cliphoard/UI/SettingsView.swift"),
            encoding: .utf8)

        for required in ["section(\"Cliphoard Pro\")",
                         "$settings.licenceKeyField",
                         "settings.verifyLicence()",
                         "settings.proOrderID",
                         "Licence.buyURL",
                         "settings.removeLicence()"] {
            XCTAssertTrue(settings.contains(required),
                          "the Cliphoard Pro section no longer wires \(required)")
        }
        // Between General and Appearance — where someone hunting for "where did my key go"
        // finds it without scrolling past the tag baskets.
        guard let general = settings.range(of: "section(\"General\")"),
              let proSection = settings.range(of: "section(\"Cliphoard Pro\")"),
              let appearance = settings.range(of: "section(\"Appearance\")") else {
            return XCTFail("a section was renamed — move this test with it")
        }
        XCTAssertLessThan(general.lowerBound, proSection.lowerBound)
        XCTAssertLessThan(proSection.lowerBound, appearance.lowerBound)
    }

    /// A key that does not verify is NOT stored. Storing it would leave Settings showing a
    /// key while the build behaves as free, which is the most confusing state a licence UI
    /// can be in and the one that generates the email.
    func testAnInvalidKeyIsNeverStored() {
        let saved = UserDefaults.standard.string(forKey: Licence.defaultsKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: Licence.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: Licence.defaultsKey) }
        }
        let store = tempStore()
        let settings = AppSettings(store: store)
        settings.licenceKeyField = "CLIP1-bm90YXJlYWxrZXk.bm90YXJlYWxzaWc"
        settings.verifyLicence()
        XCTAssertNil(UserDefaults.standard.string(forKey: Licence.defaultsKey),
                     "a key that failed verification was written to UserDefaults")
        XCTAssertFalse(store.entitlement.isPro)
        XCTAssertNotNil(settings.licenceError, "the failure must say why, not just refuse")
    }

    // MARK: - The two upsell surfaces exist, and nothing else carries one

    /// The upsells ARE the marketing, and they are the part a refactor silently drops because
    /// nothing breaks when they go. Each is pinned to the file it lives in — and the surfaces
    /// that LEFT the paid split (the Keep picker, the status-bar submenu, the Import panel) are
    /// pinned to carry no gate, no badge and no pitch.
    func testTheTwoUpsellSurfacesArePresentAndHistoryAndImportCarryNone() throws {
        func source(_ path: String) throws -> String {
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(path), encoding: .utf8)
        }
        let settings = try source("Sources/Cliphoard/UI/SettingsView.swift")
        let panel = try source("Sources/Cliphoard/UI/ContentView.swift")
        let importPanel = try source("Sources/Cliphoard/UI/ImportPanel.swift")
        let appDelegate = try source("Sources/Cliphoard/App/AppDelegate.swift")

        // 1 · the locked row in BOTH search-mode pickers
        XCTAssertTrue(panel.contains("— Pro"),
                      "the panel's mode picker no longer names the Pro row — hiding it means "
                      + "nobody ever learns the feature exists")
        XCTAssertTrue(settings.contains("SearchMode.available(settings.entitlement)"),
                      "the Settings mode picker is no longer entitlement-aware")
        // 2 · the OCR toggle
        XCTAssertTrue(settings.contains("Toggle(\"Read text in images\", isOn: $settings.imageUnderstanding)")
                      && settings.contains(".disabled(!settings.entitlement.isPro)"),
                      "the image toggle is no longer disabled for a free build")
        // 3 · the History section carries no gate, no badge, no pitch
        guard let historyStart = settings.range(of: "section(\"History\")") else {
            return XCTFail("the History section was renamed — move this test with it")
        }
        let afterHistory = settings[historyStart.upperBound...]
        let historyEnd = afterHistory.range(of: "section(\"")?.lowerBound ?? afterHistory.endIndex
        let history = String(afterHistory[..<historyEnd])
        for needle in ["— Pro", "ProPitch", "isPro", "ProBadge"] {
            XCTAssertFalse(history.contains(needle),
                           "the Keep picker still carries \(needle) — the history limit is not "
                           + "part of the paid split")
        }
        XCTAssertFalse(settings.contains("pitch(.history)"))
        XCTAssertFalse(appDelegate.contains("(Cliphoard Pro)"),
                       "the status-bar History Limit submenu still locks rows")
        XCTAssertFalse(importPanel.contains("ProPitchCard") || importPanel.contains("isPro"),
                       "the Import panel still gates the commit")
        XCTAssertNil(ProSurface(rawValue: "history"))
        XCTAssertNil(ProSurface(rawValue: "importPanel"))
        // 4 · the ceiling is gone from the whole tree, not renamed
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for case let url as URL in FileManager.default
                .enumerator(at: sources, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in ["freeHistoryLimit", "proHistoryLimits", "allowedHistoryLimit", "setHistoryLimit("] {
                XCTAssertFalse(text.contains(needle), "\(url.lastPathComponent) still names \(needle)")
            }
        }
    }

    /// One price, one place. Every surface hard-coding the number is a chance to
    /// quote a price the checkout does not charge — which for a paid product is not a typo,
    /// it is a false statement about money.
    ///
    /// Scanned as CONCRETE price tokens rather than "a currency symbol followed by a digit".
    /// The general form was tried first and matched `$0` — Swift's closure shorthand — in
    /// 200 places across files with no opinion about money whatsoever. A test that fails on
    /// `Detectors.swift`'s currency character class is a test people learn to ignore.
    func testThePriceIsWrittenExactlyOnce() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        // Every number that has been on the table for this product: the shipped $10, and the
        // arbitrated $29/£24 with its £19/$24 launch price that the owner overruled. If one
        // of those reappears in a view, the app is quoting a price nobody is charging.
        // No bare currency symbol in the list: "€" alone matched `Detectors.swift`'s
        // `[$£€¥]` class, which detects money in the USER'S clips and has no opinion about
        // what Cliphoard costs. Only amounts.
        let priceTokens = ["$10", "$29", "$24", "$19", "£24", "£19", "£29", "£10", "€10", "€29"]
        var literals: [String] = []
        for case let url as URL in FileManager.default
                .enumerator(at: sources, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" {
            guard url.lastPathComponent != "Licence.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n")
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && priceTokens.contains(where: { line.contains($0) }) {
                literals.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(literals.isEmpty,
                      "a price is written outside Licence.priceLabel: \(literals)")
        XCTAssertEqual(Licence.priceLabel, "$10")
    }
}
