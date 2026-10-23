import XCTest
@testable import Cliphoard

@MainActor
final class ExcludedAppsSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "io.antreas.cliphoard.tests.exclusions.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testExistingIDsRemainUnchangedIncludingCaseAndLegacySpelling() {
        let existing = ["com.example.SecretApp", "Legacy_Identifier", "com.example.SecretApp"]
        defaults.set(existing, forKey: "excludedBundleIDs")
        let settings = ExcludedAppsSettings(defaults: defaults)
        XCTAssertEqual(settings.bundleIDs, existing)
        XCTAssertEqual(defaults.stringArray(forKey: "excludedBundleIDs"), existing)
    }

    func testAddTrimsOnlyNewInputAndPersistsForTheMonitorAndRelaunch() {
        defaults.set(["com.existing.Private"], forKey: "excludedBundleIDs")
        let settings = ExcludedAppsSettings(defaults: defaults)
        settings.draft = "  com.example.SecretApp\n"
        XCTAssertTrue(settings.add())
        let saved = defaults.stringArray(forKey: "excludedBundleIDs")!
        XCTAssertEqual(saved, ["com.existing.Private", "com.example.SecretApp"])
        XCTAssertTrue(settings.draft.isEmpty)
        XCTAssertNil(settings.validationMessage)
        XCTAssertTrue(ClipboardMonitor.shouldSkip(frontmostBundleID: "com.example.SecretApp",
                                                   types: [], excluded: saved))
        XCTAssertTrue(ClipboardMonitor.shouldSkip(frontmostBundleID: "COM.EXAMPLE.SECRETAPP",
                                                   types: [], excluded: saved))
        XCTAssertFalse(ClipboardMonitor.shouldSkip(frontmostBundleID: "com.example.Other",
                                                    types: [], excluded: saved))
        XCTAssertEqual(ExcludedAppsSettings(defaults: defaults).bundleIDs, saved)
    }

    func testInvalidEntriesHaveVisibleReasonsAndDoNotChangeSavedIDs() {
        let existing = ["com.example.Keep"]
        defaults.set(existing, forKey: "excludedBundleIDs")
        let settings = ExcludedAppsSettings(defaults: defaults)
        for invalid in ["", "  ", "com.example two", ".com.app", "com..app", "com.app.",
                        "com.example/app", "com.example_app", "com.example.💥"] {
            settings.draft = invalid
            XCTAssertFalse(settings.add(), invalid)
            XCTAssertNotNil(settings.validationMessage, invalid)
            XCTAssertEqual(defaults.stringArray(forKey: "excludedBundleIDs"), existing)
        }
    }

    func testDuplicateIsExplainedAndEditingClearsTheMessage() {
        defaults.set(["com.example.App"], forKey: "excludedBundleIDs")
        let settings = ExcludedAppsSettings(defaults: defaults)
        settings.draft = " COM.EXAMPLE.APP "
        XCTAssertFalse(settings.add())
        XCTAssertEqual(settings.validationMessage, "That app is already excluded.")
        XCTAssertEqual(settings.bundleIDs, ["com.example.App"])
        settings.draft = "com.example.Other"
        XCTAssertNil(settings.validationMessage)
    }

    func testRemovalChangesOnlyTheSelectedAppAndCaptureCanResume() {
        defaults.set(["com.example.App", "com.example.app", "com.example.Keep"],
                     forKey: "excludedBundleIDs")
        let settings = ExcludedAppsSettings(defaults: defaults)
        settings.remove("com.example.App")
        let saved = defaults.stringArray(forKey: "excludedBundleIDs")!
        XCTAssertEqual(saved, ["com.example.Keep"], "remove all spellings of the selected app")
        XCTAssertFalse(ClipboardMonitor.shouldSkip(frontmostBundleID: "com.example.App",
                                                    types: [], excluded: saved))
        XCTAssertTrue(ClipboardMonitor.shouldSkip(frontmostBundleID: "com.example.Keep",
                                                   types: [], excluded: saved))
    }

    func testSeparateEditorsDoNotOverwriteNewerExclusions() {
        let first = ExcludedAppsSettings(defaults: defaults)
        let second = ExcludedAppsSettings(defaults: defaults)
        first.draft = "com.example.First"; XCTAssertTrue(first.add())
        second.draft = "com.example.Second"; XCTAssertTrue(second.add())
        first.remove("com.example.First")
        XCTAssertEqual(defaults.stringArray(forKey: "excludedBundleIDs"), ["com.example.Second"])
        second.reload()
        XCTAssertEqual(second.bundleIDs, ["com.example.Second"])
    }
}
