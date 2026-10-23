import Foundation

/// A verified StoreKit transaction is the only authority for the Store edition.
/// This value also lets tests exercise refunds, wrong products and failed verification
/// without making a purchase or trusting a persisted "Pro" flag.
struct StoreProTransaction: Equatable {
    static let productID = "ai.a2-labs.cliphoard.pro"

    let id: UInt64
    let originalID: UInt64
    let productID: String
    let purchased: Date
    let verified: Bool
    let nonConsumable: Bool
    var revoked: Bool = false
    var expiration: Date? = nil
    var upgraded: Bool = false

    func grantsPro(at now: Date) -> Bool {
        verified && productID == Self.productID && nonConsumable && !revoked
            && !upgraded && (expiration.map { $0 > now } ?? true)
    }

    static func entitlement(from transactions: [Self], now: Date = Date()) -> Entitlement {
        let eligible = transactions.filter { $0.grantsPro(at: now) }
        guard let transaction = eligible.max(by: {
            $0.purchased == $1.purchased ? $0.id < $1.id : $0.purchased < $1.purchased
        }) else { return .free(reason: nil) }
        return .pro(orderID: String(transaction.originalID), issued: transaction.purchased)
    }
}

#if APP_STORE
import AppKit
import Combine
import StoreKit

struct StoreProProduct: Equatable {
    let id: String
    let displayPrice: String
}

enum StoreProPurchaseResult {
    case success(StoreProTransaction)
    case pending
    case cancelled
}

/// The adapter is replaceable only by tests; production always uses StoreKitClient.
@MainActor
protocol StorePurchaseClient: AnyObject {
    func updates() -> AsyncStream<StoreProTransaction>
    func currentEntitlements() async -> [StoreProTransaction]
    func product() async throws -> StoreProProduct?
    func purchase() async throws -> StoreProPurchaseResult
    func synchronize() async throws
    func finish(_ transactionID: UInt64) async
}

@MainActor
final class StorePurchase: ObservableObject {
    static let shared = StorePurchase(client: StoreKitClient())

    @Published private(set) var entitlement: Entitlement = .free(reason: nil)
    @Published private(set) var product: StoreProProduct?
    @Published private(set) var loadingProduct = false
    @Published private(set) var isPresentingSystemSheet = false
    @Published private(set) var statusMessage: String?

    var canPurchase: Bool { product != nil && !entitlement.isPro && !isPresentingSystemSheet }
    var purchaseTitle: String {
        if loadingProduct { return "Loading Pro…" }
        return product.map { "Unlock Pro — \($0.displayPrice)" } ?? "Pro unavailable"
    }

    private let client: any StorePurchaseClient
    private weak var store: ClipStore?
    private var updatesTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    /// A slower startup/restore read must not undo a newer refund or purchase update.
    private var entitlementRevision: UInt64 = 0

    init(client: any StorePurchaseClient) { self.client = client }

    deinit {
        updatesTask?.cancel()
        startupTask?.cancel()
    }

    /// Called once at launch, before any purchase UI. Rebinding cannot add a listener.
    func start(store: ClipStore) {
        self.store = store
        store.entitlement = entitlement
        guard updatesTask == nil else { return }
        let updates = client.updates()
        updatesTask = Task { [weak self] in
            for await transaction in updates {
                guard !Task.isCancelled else { break }
                await self?.receive(transaction)
            }
        }
        startupTask = Task { [weak self] in
            await self?.refreshEntitlements()
            await self?.loadProduct()
        }
    }

    func loadProduct() async {
        guard !loadingProduct else { return }
        loadingProduct = true
        defer { loadingProduct = false }
        do {
            let loaded = try await client.product()
            product = loaded?.id == StoreProTransaction.productID ? loaded : nil
            statusMessage = product == nil
                ? "Pro is currently unavailable from the App Store. Try again later, or restore a previous purchase."
                : nil
        } catch {
            product = nil
            statusMessage = "Could not load the App Store price. Check your connection and try again."
        }
    }

    func refreshEntitlements() async {
        entitlementRevision &+= 1
        let revision = entitlementRevision
        let transactions = await client.currentEntitlements()
        guard !Task.isCancelled, revision == entitlementRevision else { return }
        apply(StoreProTransaction.entitlement(from: transactions), enableImages: false)
    }

    func purchase() async {
        guard canPurchase else { return }
        isPresentingSystemSheet = true
        statusMessage = nil
        defer { isPresentingSystemSheet = false }
        do {
            switch try await client.purchase() {
            case .success(let transaction):
                guard transaction.productID == StoreProTransaction.productID else {
                    statusMessage = "The App Store returned a different product. Pro remains locked; try Restore Purchases."
                    return
                }
                await receive(transaction)
            case .pending:
                statusMessage = "Your purchase is awaiting approval. Pro will unlock when the App Store confirms it."
            case .cancelled:
                break
            }
        } catch {
            statusMessage = "The purchase could not be completed. You have not been granted Pro; you can try again or restore a completed purchase."
        }
    }

    /// AppStore.sync can ask for authentication, so only the Restore button calls this.
    func restore() async {
        guard !isPresentingSystemSheet else { return }
        isPresentingSystemSheet = true
        statusMessage = nil
        defer { isPresentingSystemSheet = false }
        do {
            try await client.synchronize()
            await refreshEntitlements()
            statusMessage = entitlement.isPro
                ? "Pro purchases restored."
                : "No verified Pro purchase was found for this App Store account."
        } catch {
            statusMessage = "Could not restore purchases. Check your App Store account and connection, then try again."
        }
    }

    private func receive(_ transaction: StoreProTransaction) async {
        guard transaction.productID == StoreProTransaction.productID else { return }
        entitlementRevision &+= 1
        let next = StoreProTransaction.entitlement(from: [transaction])
        apply(next, enableImages: next.isPro && !entitlement.isPro)
        guard transaction.verified, transaction.nonConsumable else {
            statusMessage = "The App Store transaction could not be verified. Pro remains locked; try Restore Purchases."
            return
        }
        statusMessage = next.isPro ? "Pro is active on this Mac." : "This Pro purchase is no longer active. Your clipboard history has been kept."
        // Deliver (or revoke) first, then acknowledge the verified transaction.
        await client.finish(transaction.id)
    }

    private func apply(_ next: Entitlement, enableImages: Bool) {
        let wasPro = entitlement.isPro
        store?.entitlement = next
        entitlement = next
        if enableImages { ClipStore.setImageUnderstanding(true, entitlement: next) }
        if wasPro && !next.isPro {
            ClipStore.setImageUnderstanding(false, entitlement: next)
            if DeepSearch.mode == .image { DeepSearch.mode = .exact }
        }
        if next.isPro, let store, ClipStore.imageUnderstandingAllowed(next) {
            store.scheduleImageUnderstanding()
        }
    }
}

/// StoreKit owns transaction verification and its on-device entitlement cache. We never
/// turn an unverified payload, external licence, or UserDefaults value into a purchase.
@MainActor
private final class StoreKitClient: StorePurchaseClient {
    private var cachedProduct: Product?
    private var transactions: [UInt64: StoreKit.Transaction] = [:]

    func updates() -> AsyncStream<StoreProTransaction> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard !Task.isCancelled, let self else { break }
                    continuation.yield(self.snapshot(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func currentEntitlements() async -> [StoreProTransaction] {
        var result: [StoreProTransaction] = []
        for await transaction in StoreKit.Transaction.currentEntitlements {
            result.append(snapshot(transaction))
        }
        return result
    }

    func product() async throws -> StoreProProduct? {
        cachedProduct = try await Product.products(for: [StoreProTransaction.productID])
            .first { $0.id == StoreProTransaction.productID && $0.type == .nonConsumable }
        return cachedProduct.map { StoreProProduct(id: $0.id, displayPrice: $0.displayPrice) }
    }

    func purchase() async throws -> StoreProPurchaseResult {
        guard let product = cachedProduct else { throw StorePurchaseError.unavailable }
        let result: Product.PurchaseResult
        if #available(macOS 15.2, *), let window = NSApp.keyWindow {
            result = try await product.purchase(confirmIn: window)
        } else {
            result = try await product.purchase()
        }
        switch result {
        case .success(let verification): return .success(snapshot(verification))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw StorePurchaseError.unavailable
        }
    }

    func synchronize() async throws { try await AppStore.sync() }

    func finish(_ transactionID: UInt64) async {
        guard let transaction = transactions.removeValue(forKey: transactionID) else { return }
        await transaction.finish()
    }

    private func snapshot(_ result: VerificationResult<StoreKit.Transaction>) -> StoreProTransaction {
        let transaction: StoreKit.Transaction
        let verified: Bool
        switch result {
        case .verified(let value): transaction = value; verified = true
        case .unverified(let value, _): transaction = value; verified = false
        }
        if verified, transaction.productID == StoreProTransaction.productID {
            transactions[transaction.id] = transaction
        }
        return StoreProTransaction(id: transaction.id, originalID: transaction.originalID,
                                   productID: transaction.productID,
                                   purchased: transaction.purchaseDate, verified: verified,
                                   nonConsumable: transaction.productType == .nonConsumable,
                                   revoked: transaction.revocationDate != nil,
                                   expiration: transaction.expirationDate,
                                   upgraded: transaction.isUpgraded)
    }

    private enum StorePurchaseError: Error { case unavailable }
}
#endif
