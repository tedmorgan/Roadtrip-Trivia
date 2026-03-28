import Foundation
import Combine

/// Tracks round budgets across free, subscription, and purchased round packs.
///
/// Consumption priority:
///   1. Free round (1 per device lifetime)
///   2. Subscription rounds (reset each billing period)
///   3. Purchased round packs (never expire)
///
/// Notifies observers when `canPlayRound` changes so the UI can show/hide the paywall.
class RoundTracker: ObservableObject {

    static let shared = RoundTracker()

    // MARK: - UserDefaults Keys

    private let defaults = UserDefaults.standard
    private let kFreeRoundUsed          = "rt_freeRoundUsed"
    private let kPurchasedRounds        = "rt_purchasedRounds"
    private let kSubscriptionRoundsUsed = "rt_subscriptionRoundsUsed"
    private let kPeriodStartDate        = "rt_periodStartDate"

    // MARK: - Published State

    /// True when the user has at least one round available from any source.
    @Published private(set) var canPlayRound = true

    /// Notification posted when round budget is exhausted mid-session.
    static let roundLimitReachedNotification = Notification.Name("RoundTracker.roundLimitReached")

    /// Notification posted when the paywall should be shown.
    static let showPaywallNotification = Notification.Name("RoundTracker.showPaywall")

    private init() {
        refreshCanPlay()
    }

    // MARK: - Free Round

    var hasFreeRound: Bool {
        !defaults.bool(forKey: kFreeRoundUsed)
    }

    private func consumeFreeRound() {
        defaults.set(true, forKey: kFreeRoundUsed)
        print("[RoundTracker] Free round consumed")
    }

    // MARK: - Purchased Round Packs (Consumable IAP)

    var purchasedRoundsRemaining: Int {
        max(0, defaults.integer(forKey: kPurchasedRounds))
    }

    func addPurchasedRounds(_ count: Int) {
        let current = purchasedRoundsRemaining
        defaults.set(current + count, forKey: kPurchasedRounds)
        refreshCanPlay()
        print("[RoundTracker] Added \(count) purchased rounds — total: \(current + count)")
    }

    private func consumePurchasedRound() {
        let current = purchasedRoundsRemaining
        if current > 0 {
            defaults.set(current - 1, forKey: kPurchasedRounds)
            print("[RoundTracker] Purchased round consumed — remaining: \(current - 1)")
        }
    }

    // MARK: - Subscription Rounds

    /// Rounds used in the current subscription billing period.
    var subscriptionRoundsUsed: Int {
        resetPeriodIfNeeded()
        return defaults.integer(forKey: kSubscriptionRoundsUsed)
    }

    /// Rounds remaining in the current subscription period.
    var subscriptionRoundsRemaining: Int {
        let limit = StoreService.shared.roundsPerPeriod
        let used = subscriptionRoundsUsed
        return max(0, limit - used)
    }

    private func consumeSubscriptionRound() {
        resetPeriodIfNeeded()
        let used = defaults.integer(forKey: kSubscriptionRoundsUsed)
        defaults.set(used + 1, forKey: kSubscriptionRoundsUsed)
        print("[RoundTracker] Subscription round consumed — used: \(used + 1)/\(StoreService.shared.roundsPerPeriod)")
    }

    // MARK: - Period Reset

    /// Resets the subscription round counter when a new billing period starts.
    private func resetPeriodIfNeeded() {
        guard StoreService.shared.isSubscribed else { return }

        let lastReset = defaults.object(forKey: kPeriodStartDate) as? Date ?? .distantPast
        let periodLength: TimeInterval

        if StoreService.shared.activeSubscription == StoreProducts.weeklyPass {
            periodLength = 7 * 24 * 3600   // 1 week
        } else {
            periodLength = 30 * 24 * 3600   // ~1 month
        }

        if Date().timeIntervalSince(lastReset) >= periodLength {
            defaults.set(0, forKey: kSubscriptionRoundsUsed)
            defaults.set(Date(), forKey: kPeriodStartDate)
            print("[RoundTracker] Subscription period reset")
        }
    }

    // MARK: - Unified Consumption

    /// Attempt to consume one round. Returns true on success, false if no rounds available.
    ///
    /// Priority: free round → subscription → purchased packs.
    @discardableResult
    func consumeOneRound() -> Bool {
        // 1. Free round
        if hasFreeRound {
            consumeFreeRound()
            refreshCanPlay()
            return true
        }

        // 2. Subscription rounds
        if StoreService.shared.isSubscribed && subscriptionRoundsRemaining > 0 {
            consumeSubscriptionRound()
            refreshCanPlay()
            return true
        }

        // 3. Purchased round packs
        if purchasedRoundsRemaining > 0 {
            consumePurchasedRound()
            refreshCanPlay()
            return true
        }

        print("[RoundTracker] No rounds available")
        refreshCanPlay()
        return false
    }

    // MARK: - State Refresh

    func refreshCanPlay() {
        let available = hasFreeRound
            || (StoreService.shared.isSubscribed && subscriptionRoundsRemaining > 0)
            || purchasedRoundsRemaining > 0

        if canPlayRound != available {
            canPlayRound = available
        }
    }

    // MARK: - Total Available Rounds

    var totalRoundsAvailable: Int {
        var total = 0
        if hasFreeRound { total += 1 }
        if StoreService.shared.isSubscribed {
            total += subscriptionRoundsRemaining
        }
        total += purchasedRoundsRemaining
        return total
    }

    // MARK: - Status Summary for UI

    var statusSummary: String {
        var parts: [String] = []
        if hasFreeRound {
            parts.append("1 free round")
        }
        if StoreService.shared.isSubscribed {
            let remaining = subscriptionRoundsRemaining
            parts.append("\(remaining) subscription round\(remaining == 1 ? "" : "s")")
        }
        let purchased = purchasedRoundsRemaining
        if purchased > 0 {
            parts.append("\(purchased) purchased round\(purchased == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "No rounds available" : parts.joined(separator: " + ")
    }

    /// Short label for CarPlay home screen.
    var shortLabel: String {
        let total = totalRoundsAvailable
        if total == 0 { return "No rounds" }
        return "\(total) round\(total == 1 ? "" : "s") available"
    }
}
