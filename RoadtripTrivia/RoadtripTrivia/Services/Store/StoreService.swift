import StoreKit
import Foundation

/// Manages StoreKit 2 product loading, purchasing, and subscription status.
///
/// Thread-safety: All published properties and public methods run on @MainActor.
/// StoreKit 2 uses cryptographic on-device verification, so no server-side
/// receipt validation is required for basic entitlement checks.
@MainActor
class StoreService: ObservableObject {

    static let shared = StoreService()

    // MARK: - Published State

    /// All products fetched from App Store Connect, sorted by price.
    @Published private(set) var products: [Product] = []

    /// Product IDs of currently active auto-renewable subscriptions.
    @Published private(set) var purchasedSubscriptionIDs: Set<String> = []

    /// Convenience: true when any subscription is active.
    @Published private(set) var isSubscribed = false

    /// Set after a purchase attempt for UI feedback.
    @Published var purchaseError: String?

    // MARK: - Private

    private var transactionListener: Task<Void, Error>?

    private init() {
        transactionListener = listenForTransactions()
        Task { await loadProducts() }
        Task { await updateSubscriptionStatus() }
    }

    deinit { transactionListener?.cancel() }

    // MARK: - Load Products from App Store

    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: StoreProducts.allProductIDs)
            products = fetched.sorted { $0.price < $1.price }
            print("[Store] Loaded \(products.count) products")
        } catch {
            print("[Store] Failed to load products: \(error)")
        }
    }

    // MARK: - Purchase

    /// Initiate a purchase. Returns true on success, false on cancel/pending.
    @discardableResult
    func purchase(_ product: Product) async throws -> Bool {
        purchaseError = nil

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await handleTransaction(transaction)
            await transaction.finish()
            return true

        case .userCancelled:
            return false

        case .pending:
            // Ask-to-Buy or SCA — transaction arrives later via listener
            return false

        @unknown default:
            return false
        }
    }

    // MARK: - Restore Purchases

    func restorePurchases() async {
        do {
            try await AppStore.sync()
        } catch {
            print("[Store] Restore failed: \(error)")
        }
        await updateSubscriptionStatus()
    }

    // MARK: - Subscription Status

    func updateSubscriptionStatus() async {
        var activeIDs: Set<String> = []

        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                if transaction.productType == .autoRenewable,
                   transaction.revocationDate == nil {
                    activeIDs.insert(transaction.productID)
                }
            }
        }

        purchasedSubscriptionIDs = activeIDs
        isSubscribed = !activeIDs.isEmpty

        // Notify RoundTracker that subscription state changed
        RoundTracker.shared.refreshCanPlay()

        print("[Store] Active subscriptions: \(activeIDs)")
    }

    // MARK: - Active Subscription Tier

    /// Returns the product ID of the highest-tier active subscription.
    /// Monthly is preferred over weekly if both are somehow active.
    var activeSubscription: String? {
        if purchasedSubscriptionIDs.contains(StoreProducts.monthlyPass) {
            return StoreProducts.monthlyPass
        }
        if purchasedSubscriptionIDs.contains(StoreProducts.weeklyPass) {
            return StoreProducts.weeklyPass
        }
        return nil
    }

    /// Number of rounds the active subscription grants per billing period.
    var roundsPerPeriod: Int {
        guard let sub = activeSubscription else { return 0 }
        return StoreProducts.roundsPerPeriod(for: sub)
    }

    // MARK: - Product Helpers

    func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    var subscriptionProducts: [Product] {
        products.filter { StoreProducts.subscriptionIDs.contains($0.id) }
            .sorted { $0.price < $1.price }
    }

    var consumableProducts: [Product] {
        products.filter { StoreProducts.consumableIDs.contains($0.id) }
            .sorted { $0.price < $1.price }
    }

    // MARK: - Transaction Listener

    /// Listens for transaction updates (renewals, revocations, Ask-to-Buy completions).
    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                if let transaction = try? self?.checkVerified(result) {
                    await self?.handleTransaction(transaction)
                    await transaction.finish()
                }
            }
        }
    }

    private func handleTransaction(_ transaction: Transaction) async {
        if StoreProducts.consumableIDs.contains(transaction.productID) {
            let rounds = StoreProducts.roundsForProduct(transaction.productID)
            RoundTracker.shared.addPurchasedRounds(rounds)
            print("[Store] Consumable purchased: +\(rounds) rounds")
        }
        await updateSubscriptionStatus()
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            print("[Store] Transaction verification failed: \(error)")
            throw error
        case .verified(let safe):
            return safe
        }
    }
}
