#if APP_STORE
import XCTest
import AppKit
@testable import Cliphoard

@MainActor
private final class PricePresentationClient: StorePurchaseClient {
    var offered = StoreProProduct(id: StoreProTransaction.productID, displayPrice: "US$10.00")
    var transactionUpdates: AsyncStream<StoreProTransaction>.Continuation?
    var storefrontChanges: AsyncStream<Void>.Continuation?
    var holdNextProduct = false
    var heldProduct: CheckedContinuation<StoreProProduct?, Error>?
    var productRequests = 0
    var purchases = 0
    var productError = false
    var purchaseError = false
    var onPurchase: (() -> Void)?
    var onSynchronize: (() -> Void)?

    func updates() -> AsyncStream<StoreProTransaction> { AsyncStream { transactionUpdates = $0 } }
    func storefrontUpdates() -> AsyncStream<Void> { AsyncStream { storefrontChanges = $0 } }
    func currentEntitlements() async -> [StoreProTransaction] { [] }
    func product() async throws -> StoreProProduct? {
        productRequests += 1
        if productError { throw NSError(domain: "PricePresentationTests", code: 1) }
        if holdNextProduct {
            holdNextProduct = false
            return try await withCheckedThrowingContinuation { heldProduct = $0 }
        }
        return offered
    }
    func purchase(confirmIn window: NSWindow?) async throws -> StoreProPurchaseResult {
        purchases += 1
        if purchaseError { throw NSError(domain: "PricePresentationTests", code: 2) }
        onPurchase?()
        return .cancelled
    }
    func synchronize() async throws { onSynchronize?() }
    func finish(_ transactionID: UInt64) async {}
}

/// Intentionally independent of ClipStore: no Keychain or durable preferences.
@MainActor
final class StorePricePresentationTests: XCTestCase {
    private func settle(_ predicate: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("price state did not settle", file: file, line: line)
    }

    func testPurchaseAndRestorePrepareTheirHostWhileDismissalIsBlocked() async {
        let client = PricePresentationClient()
        let purchase = StorePurchase(client: client)
        var prepared = 0
        purchase.presentationWindow = {
            XCTAssertTrue(purchase.isPresentingSystemSheet)
            prepared += 1
            return nil // no real window or App Store UI in this adapter test
        }
        client.onPurchase = { XCTAssertEqual(prepared, 1) }
        client.onSynchronize = { XCTAssertEqual(prepared, 2) }
        await purchase.loadProduct()
        await purchase.purchase()
        XCTAssertEqual(client.purchases, 1)
        XCTAssertFalse(purchase.isPresentingSystemSheet)
        await purchase.restore()
        XCTAssertEqual(prepared, 2)
        XCTAssertFalse(purchase.isPresentingSystemSheet)
    }

    func testChangedPriceRequiresReviewBeforeStartingAPurchase() async {
        let client = PricePresentationClient()
        let purchase = StorePurchase(client: client)
        await purchase.loadProduct()
        client.offered = .init(id: StoreProTransaction.productID, displayPrice: "£10.00")
        await purchase.purchase()
        XCTAssertEqual(client.purchases, 0)
        XCTAssertEqual(purchase.purchaseTitle, "Unlock Pro — £10.00")
        XCTAssertTrue(purchase.statusMessage?.contains("offer has updated") == true)
        XCTAssertFalse(purchase.isPresentingSystemSheet)
        await purchase.purchase()
        XCTAssertEqual(client.purchases, 1)
    }

    func testIdenticalPriceLabelsDoNotHideChangedCurrencyOrStorefront() async {
        for changed in [StoreProProduct(id: StoreProTransaction.productID, displayPrice: "$10.00",
                                        price: 10, currencyCode: "CAD", storefrontID: "Canada"),
                        StoreProProduct(id: StoreProTransaction.productID, displayPrice: "$10.00",
                                        price: 10, currencyCode: "USD", storefrontID: "Another storefront")] {
            let client = PricePresentationClient()
            client.offered = .init(id: StoreProTransaction.productID, displayPrice: "$10.00",
                                  price: 10, currencyCode: "USD", storefrontID: "USA")
            let purchase = StorePurchase(client: client)
            await purchase.loadProduct()
            client.offered = changed
            await purchase.purchase()
            XCTAssertEqual(client.purchases, 0, "the visible label is not the complete offer identity")
            XCTAssertTrue(purchase.statusMessage?.contains("offer has updated") == true)
            XCTAssertTrue(purchase.canPurchase, "the updated offer can be deliberately selected")
        }
    }

    func testStorefrontChangeRefreshesAndCoalescesAnInFlightOldPrice() async {
        let client = PricePresentationClient()
        let purchase = StorePurchase(client: client)
        purchase.startObserving()
        await settle { purchase.canPurchase }
        client.holdNextProduct = true
        let oldRead = Task { await purchase.loadProduct() }
        await settle { client.heldProduct != nil }
        XCTAssertFalse(purchase.canPurchase)
        client.offered = .init(id: StoreProTransaction.productID, displayPrice: "€12,34")
        client.storefrontChanges?.yield(())
        await settle { purchase.product == nil }
        client.heldProduct?.resume(returning: .init(id: StoreProTransaction.productID, displayPrice: "US$10.00"))
        client.heldProduct = nil
        await oldRead.value
        await settle { purchase.canPurchase }
        XCTAssertEqual(purchase.purchaseTitle, "Unlock Pro — €12,34")
        XCTAssertEqual(client.productRequests, 3)
        client.storefrontChanges?.finish()
        client.transactionUpdates?.finish()
    }

    func testPreflightFailureCannotPurchaseTheCachedOfferAndReleasesDismissal() async {
        let client = PricePresentationClient()
        let purchase = StorePurchase(client: client)
        await purchase.loadProduct()
        client.productError = true
        await purchase.purchase()
        XCTAssertEqual(client.purchases, 0)
        XCTAssertNil(purchase.product)
        XCTAssertFalse(purchase.isPresentingSystemSheet)
        XCTAssertFalse(purchase.canPurchase)
        XCTAssertTrue(purchase.statusMessage?.contains("Could not load") == true)
    }

    func testEveryCoalescedCallerWaitsForTheFreshPrice() async {
        let client = PricePresentationClient()
        let purchase = StorePurchase(client: client)
        await purchase.loadProduct()
        client.holdNextProduct = true
        let first = Task { await purchase.loadProduct() }
        await settle { client.heldProduct != nil }
        client.offered = .init(id: StoreProTransaction.productID, displayPrice: "€12,34")
        var secondStarted = false
        var secondFinished = false
        let second = Task {
            secondStarted = true
            await purchase.loadProduct()
            secondFinished = true
        }
        await settle { secondStarted }
        XCTAssertFalse(secondFinished, "await loadProduct must not return an in-flight old offer")
        client.heldProduct?.resume(returning: .init(id: StoreProTransaction.productID, displayPrice: "US$10.00"))
        client.heldProduct = nil
        await first.value
        await second.value
        XCTAssertTrue(secondFinished)
        XCTAssertEqual(purchase.purchaseTitle, "Unlock Pro — €12,34")
    }

    func testPurchaseFailureReleasesDismissalAndAllowsRetry() async {
        let client = PricePresentationClient()
        let purchase = StorePurchase(client: client)
        await purchase.loadProduct()
        client.purchaseError = true
        await purchase.purchase()
        XCTAssertEqual(client.purchases, 1)
        XCTAssertFalse(purchase.entitlement.isPro)
        XCTAssertFalse(purchase.isPresentingSystemSheet)
        XCTAssertTrue(purchase.canPurchase)
        XCTAssertTrue(purchase.statusMessage?.contains("could not be completed") == true)
    }
}
#endif
