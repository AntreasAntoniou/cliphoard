import XCTest
@testable import Cliphoard

/// The test target must not be able to write to the user's real keychain.
///
/// It could, and it did. `Crypto.service` was one constant shared by the app and by
/// `swift test`, and keychain items are keyed by service ACROSS PROCESSES — unlike
/// `UserDefaults`, which macOS scopes per bundle id for free. So the suite inherited write
/// access to production secrets by default. The result, in a live login keychain: twenty
/// `db-archived-key-unit-test-key*` items, a confirmation dialog per item on every launch,
/// and a `db-canary-v1` that a test process could overwrite while the app's freeze depended
/// on it.
///
/// Every test here is PURE — it asserts the decision, never the keychain — so none of them
/// can raise a dialog, and the shipping direction is assertable even though this process is
/// by definition the other case.
final class KeychainNamespaceTests: XCTestCase {

    // MARK: - The direction that matters most

    /// A SHIPPING process must resolve to production. This is the catastrophic direction: a
    /// namespace that is always the test one stops the pollution AND makes the app unable to
    /// read a single real clip — it would open, find nothing, and tell the user their history
    /// is empty. Every other test in this file would still pass.
    ///
    /// Asserted through the pure predicate because a test process cannot BE the shipping
    /// configuration. That is the whole reason the decision was extracted.
    func testAShippingProcessResolvesToProduction() {
        XCTAssertEqual(Crypto.serviceName(xctestLoaded: false, bundleID: "io.antreas.cliphoard"),
                       Crypto.productionService)
        XCTAssertEqual(Crypto.serviceName(xctestLoaded: false, bundleID: nil),
                       Crypto.productionService,
                       "an unknown bundle id is not evidence of a test — default to production")
        XCTAssertEqual(Crypto.serviceName(xctestLoaded: false, bundleID: "com.other.app"),
                       Crypto.productionService)
    }

    /// The CONJUNCTION, which is what makes the catastrophic direction need TWO independent
    /// failures rather than one. XCTest loaded inside the shipping bundle must STILL be
    /// production — otherwise anything that manages to load XCTest into the app (a plugin, a
    /// debugger, a future dependency) silently hides the user's history.
    func testXCTestInsideTheShippingBundleIsStillProduction() {
        XCTAssertEqual(Crypto.serviceName(xctestLoaded: true, bundleID: "io.antreas.cliphoard"),
                       Crypto.productionService,
                       "changing the conjunction to a disjunction makes a shipping app that "
                       + "somehow loads XCTest read an empty test namespace")
    }

    /// And the case that must be the test namespace, or the pollution simply continues.
    func testATestProcessResolvesToItsOwnNamespace() {
        let name = Crypto.serviceName(xctestLoaded: true, bundleID: "com.apple.dt.xctest.tool")
        XCTAssertTrue(name.hasPrefix(Crypto.testServicePrefix))
        XCTAssertNotEqual(name, Crypto.productionService)
        XCTAssertTrue(name.contains("\(ProcessInfo.processInfo.processIdentifier)"),
                      "the namespace must be PER-RUN. A fixed test service accumulates items "
                      + "written by successive ad-hoc-signed test binaries whose code "
                      + "identities are already gone, so the next run needs a dialog for every "
                      + "one of them — the trap relocated, not escaped. That is literally how "
                      + "the twenty junk items accumulated.")
    }

    /// Two resolutions must differ, or the per-run property is decorative.
    func testTwoResolutionsDoNotCollide() {
        let a = Crypto.serviceName(xctestLoaded: true, bundleID: "x")
        let b = Crypto.serviceName(xctestLoaded: true, bundleID: "x")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - The sweep can never reach production

    /// The start-of-run sweep deletes WHOLE SERVICES by prefix. If that prefix could ever
    /// match the production service, it would delete every key the user owns — the single
    /// worst bug this file could contain. Asserted in BOTH directions, because "which string
    /// is the prefix" is exactly the kind of thing a refactor flips.
    func testTheTestPrefixCannotReachTheProductionService() {
        XCTAssertFalse(Crypto.productionService.hasPrefix(Crypto.testServicePrefix))
        XCTAssertFalse(Crypto.testServicePrefix.hasPrefix(Crypto.productionService))
        XCTAssertNotEqual(Crypto.productionService.first, Crypto.testServicePrefix.first,
                          "they differ from the first character, which is deliberate")
    }

    /// The production service is a constant of the USER'S DATA, not a name to keep in sync
    /// with the app. The bundle id has already moved (ai.axiotic.ditto → io.antreas.cliphoard)
    /// and this deliberately did not follow it: every key the user owns is filed under this
    /// exact string, so renaming it is a data migration, not a rename.
    func testTheProductionServiceStringIsFrozen() {
        XCTAssertEqual(Crypto.productionService, "ai.axiotic.ditto")
    }

    // MARK: - This very process

    /// If this fails, the suite is writing to the user's real keychain right now.
    func testThisProcessIsNotOnTheProductionNamespace() {
        XCTAssertNotEqual(Crypto.service, Crypto.productionService,
                          "the test target resolved to the PRODUCTION keychain service")
        XCTAssertTrue(Crypto.service.hasPrefix(Crypto.testServicePrefix))
    }

    // MARK: - Write outcomes

    /// A `Bool` could not distinguish "stored in the prompt-free keychain" from "stored in the
    /// legacy one" — both are success, and telling them apart is the entire purpose of the
    /// migrate-forward path. The build deployed on 2026-08-08 logged "migrated … future
    /// launches need no prompt" immediately after that write returned `errSecMissingEntitlement`.
    func testBothKeychainOutcomesCountAsDurableButOnlyOneIsPromptFree() {
        XCTAssertTrue(Crypto.KeychainWrite.dataProtection.isDurable)
        XCTAssertTrue(Crypto.KeychainWrite.legacyFallback(errSecMissingEntitlement).isDurable,
                      "a legacy fallback IS stored. Treating it as failure would stop first run "
                      + "on any self-signed build from persisting a key at all — far worse than "
                      + "the dialog it avoids.")
        XCTAssertFalse(Crypto.KeychainWrite.failed(errSecAuthFailed).isDurable)
        XCTAssertTrue(Crypto.KeychainWrite.failed(errSecAuthFailed).isFailure)
        XCTAssertFalse(Crypto.KeychainWrite.dataProtection.isFailure)
        XCTAssertNotEqual(Crypto.KeychainWrite.dataProtection,
                          .legacyFallback(errSecSuccess),
                          "the two success cases must remain distinguishable — collapsing them "
                          + "is what let a false 'no future launch needs a prompt' be logged")
    }
}
