import XCTest
@testable import Cliphoard

final class StoreProEntitlementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func transaction(productID: String = StoreProTransaction.productID,
                             verified: Bool = true, nonConsumable: Bool = true) -> StoreProTransaction {
        StoreProTransaction(id: 12, originalID: 10, productID: productID,
                            purchased: Date(timeIntervalSince1970: 100),
                            verified: verified, nonConsumable: nonConsumable)
    }

    func testOnlyVerifiedMatchingNonConsumableUnlocksPro() {
        XCTAssertEqual(StoreProTransaction.entitlement(from: [transaction()], now: now),
                       .pro(orderID: "10", issued: Date(timeIntervalSince1970: 100)))
        for rejected in [transaction(productID: "unrelated.product"), transaction(verified: false),
                         transaction(nonConsumable: false)] {
            XCTAssertFalse(StoreProTransaction.entitlement(from: [rejected], now: now).isPro)
        }
        XCTAssertFalse(StoreProTransaction.entitlement(from: [], now: now).isPro)
    }

    func testRefundExpirationAndUpgradeDoNotGrantPro() {
        var revoked = transaction(); revoked.revoked = true
        var expired = transaction(); expired.expiration = now
        var upgraded = transaction(); upgraded.upgraded = true
        for rejected in [revoked, expired, upgraded] {
            XCTAssertFalse(StoreProTransaction.entitlement(from: [rejected], now: now).isPro)
        }
    }

    func testAnotherInvalidTransactionCannotHideAValidEntitlement() {
        var revoked = transaction(); revoked.revoked = true
        XCTAssertTrue(StoreProTransaction.entitlement(from: [revoked, transaction(verified: false),
                                                             transaction()], now: now).isPro)
    }
}

#if APP_STORE
@MainActor
private final class FakeStorePurchaseClient: StorePurchaseClient {
    var current: [StoreProTransaction] = []
    var offeredProduct: StoreProProduct? = .init(id: StoreProTransaction.productID, displayPrice: "€12,34")
    var outcome: StoreProPurchaseResult = .cancelled
    var syncError = false
    var purchaseError = false
    var purchases = 0
    var listeners = 0
    var syncs = 0
    var finished: [UInt64] = []
    var continuation: AsyncStream<StoreProTransaction>.Continuation?
    var heldEntitlements: CheckedContinuation<[StoreProTransaction], Never>?
    var holdNextRead = false
    var onFinish: (() -> Void)?

    func updates() -> AsyncStream<StoreProTransaction> {
        listeners += 1
        return AsyncStream { continuation = $0 }
    }
    func currentEntitlements() async -> [StoreProTransaction] {
        if holdNextRead {
            holdNextRead = false
            return await withCheckedContinuation { heldEntitlements = $0 }
        }
        return current
    }
    func product() async throws -> StoreProProduct? { offeredProduct }
    func purchase() async throws -> StoreProPurchaseResult {
        purchases += 1
        if purchaseError { throw NSError(domain: "StorePurchaseTests", code: 2) }
        return outcome
    }
    func synchronize() async throws {
        syncs += 1
        if syncError { throw NSError(domain: "StorePurchaseTests", code: 1) }
    }
    func finish(_ transactionID: UInt64) async { onFinish?(); finished.append(transactionID) }
}

@MainActor
final class StorePurchaseLifecycleTests: XCTestCase {
    private var directory: URL!
    private var store: ClipStore!
    private var defaults: [String: Any] = [:]
    private let keys = ["imageUnderstandingEnabled", "searchMode", "deepSearchLevel", "historyLimit", Licence.defaultsKey]

    override func setUpWithError() throws {
        for key in keys { defaults[key] = UserDefaults.standard.object(forKey: key) }
        try skipIfKeychainUnreachable()
        DeepSearch.level = .off
        DeepSearch.mode = .exact
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CliphoardStoreTests-\(UUID().uuidString)")
        store = ClipStore(directory: directory)
        store.historyLimit = 0
    }

    override func tearDownWithError() throws {
        store = nil
        for key in keys {
            if let value = defaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func transaction(revoked: Bool = false, verified: Bool = true) -> StoreProTransaction {
        StoreProTransaction(id: 12, originalID: 10, productID: StoreProTransaction.productID,
                            purchased: Date(timeIntervalSince1970: 100), verified: verified,
                            nonConsumable: true, revoked: revoked)
    }

    private func settle(_ predicate: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("asynchronous Store state did not settle", file: file, line: line)
    }

    func testStartupRestoresVerifiedCacheWithoutAuthenticationOrPriceDependency() async {
        let client = FakeStorePurchaseClient(); client.current = [transaction()]; client.offeredProduct = nil
        let purchase = StorePurchase(client: client)
        purchase.start(store: store)
        await settle { purchase.entitlement.isPro }
        XCTAssertTrue(store.entitlement.isPro)
        XCTAssertEqual(client.syncs, 0, "startup must not prompt for App Store authentication")
        XCTAssertEqual(client.purchases, 0)
    }

    func testPendingAndCancellationStayFreeAndNeverFinish() async {
        let client = FakeStorePurchaseClient()
        let purchase = StorePurchase(client: client)
        await purchase.loadProduct()
        XCTAssertTrue(purchase.purchaseTitle.contains("€12,34"), "use StoreKit's localized price")
        client.outcome = .pending
        await purchase.purchase()
        XCTAssertFalse(purchase.entitlement.isPro)
        XCTAssertTrue(purchase.statusMessage?.contains("approval") == true)
        XCTAssertFalse(purchase.isPresentingSystemSheet)
        client.outcome = .cancelled
        await purchase.purchase()
        XCTAssertFalse(purchase.entitlement.isPro)
        XCTAssertNil(purchase.statusMessage)
        XCTAssertTrue(client.finished.isEmpty)
    }

    func testVerifiedPurchaseDeliversBeforeFinishAndUnverifiedPurchaseDoesNotFinish() async {
        let client = FakeStorePurchaseClient()
        let purchase = StorePurchase(client: client)
        await purchase.loadProduct()
        client.outcome = .success(transaction(verified: false))
        await purchase.purchase()
        XCTAssertFalse(purchase.entitlement.isPro)
        XCTAssertTrue(client.finished.isEmpty)
        client.outcome = .success(transaction())
        client.onFinish = { XCTAssertTrue(purchase.entitlement.isPro) }
        await purchase.purchase()
        XCTAssertTrue(purchase.entitlement.isPro)
        XCTAssertEqual(client.finished, [12])
        XCTAssertFalse(purchase.isPresentingSystemSheet)
    }

    func testRestoreIsExplicitAndCannotTrustAnUnverifiedEntitlement() async {
        let client = FakeStorePurchaseClient()
        let purchase = StorePurchase(client: client)
        client.current = [transaction(verified: false)]
        await purchase.restore()
        XCTAssertEqual(client.syncs, 1)
        XCTAssertFalse(purchase.entitlement.isPro)
        client.current = [transaction()]
        await purchase.restore()
        XCTAssertEqual(client.syncs, 2)
        XCTAssertTrue(purchase.entitlement.isPro)
        client.syncError = true
        await purchase.restore()
        XCTAssertFalse(purchase.isPresentingSystemSheet)
        XCTAssertTrue(purchase.statusMessage?.contains("Could not restore") == true)
    }

    func testRefundUpdateRemovesFeaturesButKeepsHistoryAndUnlimitedLimit() async {
        let client = FakeStorePurchaseClient(); client.current = [transaction()]
        let purchase = StorePurchase(client: client)
        purchase.start(store: store)
        await settle { purchase.entitlement.isPro }
        let item = ClipItem(kind: .text, text: "synthetic Store refund retention")
        store.add(item)
        let ids = store.items.map(\.id)
        DeepSearch.mode = .image
        client.continuation?.yield(transaction(revoked: true))
        await settle { !purchase.entitlement.isPro }
        XCTAssertFalse(store.entitlement.isPro)
        XCTAssertFalse(ClipStore.imageUnderstandingAllowed(store.entitlement))
        XCTAssertEqual(DeepSearch.mode, .exact)
        XCTAssertEqual(store.items.map(\.id), ids)
        XCTAssertEqual(store.historyLimit, 0)
        XCTAssertTrue(ProGate.allowsHistoryArchive)
    }

    func testRefundWinsOverAnOlderInFlightEntitlementRead() async {
        let client = FakeStorePurchaseClient(); client.current = [transaction()]
        let purchase = StorePurchase(client: client)
        purchase.start(store: store)
        await settle { purchase.entitlement.isPro }
        client.holdNextRead = true
        let refresh = Task { await purchase.refreshEntitlements() }
        await settle { client.heldEntitlements != nil }
        client.continuation?.yield(transaction(revoked: true))
        await settle { !purchase.entitlement.isPro }
        client.heldEntitlements?.resume(returning: [transaction()])
        client.heldEntitlements = nil
        await refresh.value
        XCTAssertFalse(purchase.entitlement.isPro, "a stale read must not restore a refunded unlock")
    }

    func testMissingOrWrongProductCannotStartAPurchase() async {
        let client = FakeStorePurchaseClient()
        client.offeredProduct = .init(id: "another.product", displayPrice: "€12,34")
        let purchase = StorePurchase(client: client)
        await purchase.loadProduct()
        await purchase.purchase()
        XCTAssertFalse(purchase.canPurchase)
        XCTAssertEqual(client.purchases, 0)
    }

    func testPurchaseFailureReleasesTheSystemSheetAndKeepsFreeAvailable() async {
        let client = FakeStorePurchaseClient(); client.purchaseError = true
        let purchase = StorePurchase(client: client)
        await purchase.loadProduct()
        await purchase.purchase()
        XCTAssertFalse(purchase.entitlement.isPro)
        XCTAssertFalse(purchase.isPresentingSystemSheet)
        XCTAssertTrue(purchase.canPurchase)
        XCTAssertTrue(purchase.statusMessage?.contains("could not be completed") == true)
        XCTAssertTrue(client.finished.isEmpty)
    }

    func testApprovalUpdateUnlocksAfterPendingAndStartDoesNotDuplicateListener() async {
        let client = FakeStorePurchaseClient(); client.outcome = .pending
        let purchase = StorePurchase(client: client)
        purchase.start(store: store)
        purchase.start(store: store)
        await settle { purchase.canPurchase }
        await purchase.purchase()
        XCTAssertFalse(store.entitlement.isPro)
        client.continuation?.yield(transaction())
        await settle { self.store.entitlement.isPro }
        XCTAssertEqual(client.listeners, 1)
        XCTAssertEqual(client.finished, [12])
    }

    func testSettingsFollowPurchaseAndRefundWithoutConsumingAnExternalKey() async {
        let client = FakeStorePurchaseClient()
        let purchase = StorePurchase(client: client)
        purchase.start(store: store)
        await settle { purchase.canPurchase }
        let settings = AppSettings(store: store)
        UserDefaults.standard.set("external-key-fixture", forKey: Licence.defaultsKey)
        XCTAssertTrue(settings.licenceKeyField.isEmpty)
        settings.licenceKeyField = "CLIP1-irrelevant.key"
        settings.verifyLicence()
        XCTAssertFalse(store.entitlement.isPro)
        XCTAssertEqual(UserDefaults.standard.string(forKey: Licence.defaultsKey), "external-key-fixture")
        client.outcome = .success(transaction())
        await purchase.purchase()
        await settle { settings.imageUnderstanding }
        XCTAssertTrue(settings.entitlement.isPro)
        // The retired direct-key command cannot revoke an App Store purchase either.
        settings.removeLicence()
        XCTAssertTrue(settings.entitlement.isPro)
        client.continuation?.yield(transaction(revoked: true))
        await settle { !settings.imageUnderstanding && !settings.entitlement.isPro }
        XCTAssertEqual(UserDefaults.standard.string(forKey: Licence.defaultsKey), "external-key-fixture")
        XCTAssertEqual(settings.historyLimit, 0)
    }

    func testLaunchRefreshPreservesAnExplicitImageOptOut() async {
        UserDefaults.standard.set(false, forKey: "imageUnderstandingEnabled")
        let client = FakeStorePurchaseClient(); client.current = [transaction()]
        let purchase = StorePurchase(client: client)
        purchase.start(store: store)
        await settle { purchase.entitlement.isPro }
        XCTAssertFalse(ClipStore.imageUnderstandingAllowed(store.entitlement))
        await purchase.refreshEntitlements()
        XCTAssertFalse(ClipStore.imageUnderstandingAllowed(store.entitlement))
    }
}
#endif
