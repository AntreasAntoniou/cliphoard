import Foundation

/// Distribution identity can change; existing user data namespaces must survive it.
enum AppIdentity {
    static let bundleIdentifier = "ai.a2-labs.cliphoard"
    static let legacyBundleIdentifier = "io.antreas.cliphoard"
    static let preferencesMigrationKey = "a2LabsPreferencesMigratedV1"

    static func isProductionBundle(_ identifier: String?) -> Bool {
        identifier == bundleIdentifier || identifier == legacyBundleIdentifier
    }

    /// Run before any store, licence or settings initialization. XCTest and CLI tools
    /// without the shipping bundle identity must never touch these real domains.
    static func migratePreferencesIfNeeded() {
#if !APP_STORE
        guard Bundle.main.bundleIdentifier == bundleIdentifier else { return }
        migratePreferences(.standard, from: legacyBundleIdentifier, to: bundleIdentifier)
#endif
    }

    /// Merge only missing persistent values, not registered defaults. Retain the old
    /// domain for rollback. The marker prevents a later licence removal or preference
    /// reset from resurrecting a value from the old app on the next launch.
    static func migratePreferences(_ defaults: UserDefaults, from legacyDomain: String,
                                   to currentDomain: String) {
        guard legacyDomain != currentDomain else { return }
        var current = defaults.persistentDomain(forName: currentDomain) ?? [:]
        guard current[preferencesMigrationKey] as? Bool != true else { return }
        let legacy = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        for (key, value) in legacy where current[key] == nil {
            current[key] = value
        }
        current[preferencesMigrationKey] = true
        defaults.setPersistentDomain(current, forName: currentDomain)
    }
}
