import XCTest
@testable import Cliphoard

final class AppIdentityTests: XCTestCase {
    private var legacy: String!
    private var current: String!
    private var defaults: UserDefaults!

    override func setUp() {
        legacy = "io.antreas.cliphoard.tests.identity.legacy.\(UUID().uuidString)"
        current = "io.antreas.cliphoard.tests.identity.current.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: current)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: legacy)
        defaults.removePersistentDomain(forName: current)
    }

    func testMigratesAllStoredSettingsWithoutChangingLegacyDomain() {
        let old: [String: Any] = ["historyLimit": 0, "themePreset": "dark",
                                  "excludedBundleIDs": ["com.example.private"],
                                  Licence.defaultsKey: "synthetic-licence-fixture",
                                  "soundEnabled": false]
        defaults.setPersistentDomain(old, forName: legacy)
        AppIdentity.migratePreferences(defaults, from: legacy, to: current)
        let migrated = defaults.persistentDomain(forName: current)!
        for (key, value) in old {
            XCTAssertEqual(migrated[key] as? NSObject, value as? NSObject, key)
        }
        XCTAssertEqual(defaults.persistentDomain(forName: legacy)! as NSDictionary,
                       old as NSDictionary)
    }

    func testNewValuesWinIncludingFalseZeroAndEmptyValues() {
        defaults.setPersistentDomain(["historyLimit": 500, "soundEnabled": true,
                                      "excludedBundleIDs": ["old"],
                                      Licence.defaultsKey: "old-key"], forName: legacy)
        let newer: [String: Any] = ["historyLimit": 0, "soundEnabled": false,
                                   "excludedBundleIDs": [], Licence.defaultsKey: ""]
        defaults.setPersistentDomain(newer, forName: current)
        AppIdentity.migratePreferences(defaults, from: legacy, to: current)
        let migrated = defaults.persistentDomain(forName: current)!
        for (key, value) in newer {
            XCTAssertEqual(migrated[key] as? NSObject, value as? NSObject, key)
        }
    }

    func testRemovedLicenceAndResetPreferenceDoNotReturnOnRelaunch() {
        defaults.setPersistentDomain([Licence.defaultsKey: "old-key", "themePreset": "dark"],
                                     forName: legacy)
        AppIdentity.migratePreferences(defaults, from: legacy, to: current)
        defaults.removeObject(forKey: Licence.defaultsKey)
        defaults.removeObject(forKey: "themePreset")
        let relaunched = UserDefaults(suiteName: current)!
        AppIdentity.migratePreferences(relaunched, from: legacy, to: current)
        let result = relaunched.persistentDomain(forName: current)!
        XCTAssertNil(result[Licence.defaultsKey])
        XCTAssertNil(result["themePreset"])
        XCTAssertEqual(result[AppIdentity.preferencesMigrationKey] as? Bool, true)
    }

    func testFreshInstallDoesNotImportOldAppPreferencesOnLaterLaunch() {
        AppIdentity.migratePreferences(defaults, from: legacy, to: current)
        defaults.setPersistentDomain([Licence.defaultsKey: "late-old-key"], forName: legacy)
        AppIdentity.migratePreferences(defaults, from: legacy, to: current)
        XCTAssertNil(defaults.persistentDomain(forName: current)![Licence.defaultsKey])
    }

    func testBothShippingIdentitiesKeepTheProductionKeyService() {
        for identity in [AppIdentity.bundleIdentifier, AppIdentity.legacyBundleIdentifier] {
            for loaded in [false, true] {
                XCTAssertEqual(Crypto.serviceName(xctestLoaded: loaded, bundleID: identity),
                               "ai.axiotic.ditto")
            }
        }
        XCTAssertFalse(AppIdentity.isProductionBundle("com.apple.dt.xctest.tool"))
        XCTAssertFalse(AppIdentity.isProductionBundle(nil))
    }

    func testDistributionPlistMatchesCompanyIdentityAndRetainsArchiveType() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil)
                                 as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, AppIdentity.bundleIdentifier)
        let declarations = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        XCTAssertEqual(declarations.first?["UTTypeIdentifier"] as? String,
                       "io.antreas.cliphoard.archive")
    }

    func testDefaultKeychainGroupSurvivesCompanyIdentityChange() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Scripts/Cliphoard.entitlements"))
        let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil)
                                        as? [String: Any])
        XCTAssertEqual(entitlements["keychain-access-groups"] as? [String],
                       ["$(AppIdentifierPrefix)io.antreas.cliphoard"])
    }
}
