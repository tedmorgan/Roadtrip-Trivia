# Roadtrip Trivia — Subscription & IAP Implementation Plan

## Pricing Model Summary

| Product | Type | Price | Rounds Included |
|---------|------|-------|-----------------|
| Free tier | Built-in | $0 | 1 round per device/user (lifetime) |
| Weekly Pass | Auto-renewable subscription | $4.99/week | 5 rounds/week (reset each billing cycle) |
| Monthly Pass | Auto-renewable subscription | $12.99/month | 10 rounds/month (reset each billing cycle) |
| 3-Round Pack | Consumable IAP | $2.99 | 3 rounds (never expire) |
| 10-Round Pack | Consumable IAP | $9.99 | 10 rounds (never expire) |

---

## Part 1: Apple App Store Connect Configuration

### 1.1 Create a Subscription Group

In **App Store Connect → Your App → Monetization → Subscriptions**:

- Create a subscription group named **"Roadtrip Trivia Pass"**
- Add two subscriptions inside it:

| Reference Name | Product ID | Duration | Price |
|----------------|-----------|----------|-------|
| Weekly Pass | `com.nagrom.roadtrip.weekly` | 1 Week | $4.99 |
| Monthly Pass | `com.nagrom.roadtrip.monthly` | 1 Month | $12.99 |

Set the **subscription group display name** and localized descriptions (these appear on the App Store subscription management screen).

**Subscription ranking** within the group controls upgrade/downgrade behavior. Place Monthly above Weekly — if a user switches from Weekly → Monthly it's treated as an upgrade (takes effect immediately); Monthly → Weekly is a downgrade (takes effect at end of current period).

### 1.2 Create Consumable IAP Products

In **App Store Connect → Your App → Monetization → In-App Purchases**:

| Reference Name | Product ID | Type | Price |
|----------------|-----------|------|-------|
| 3 Round Pack | `com.nagrom.roadtrip.rounds.3` | Consumable | $2.99 |
| 10 Round Pack | `com.nagrom.roadtrip.rounds.10` | Consumable | $9.99 |

### 1.3 Create a StoreKit Configuration File (for testing)

In Xcode: **File → New → StoreKit Configuration File**. Name it `RoadtripTriviaStore.storekit`. Add all 4 products matching the IDs above. This lets you test purchases in the simulator without a sandbox account.

Enable it in your scheme: **Edit Scheme → Run → Options → StoreKit Configuration → RoadtripTriviaStore.storekit**.

### 1.4 App Store Server Notifications (Optional but Recommended)

In **App Store Connect → App → General → App Information → App Store Server Notifications**:

Set the URL to a Supabase Edge Function endpoint (see Part 3). This lets your server know instantly when a user renews, cancels, gets a refund, or enters billing retry — so you can update their entitlements server-side without waiting for the app to check.

---

## Part 2: New Swift Files

### 2.1 `Services/Store/StoreProducts.swift` — Product ID Constants

```swift
import Foundation

enum StoreProducts {
    // Subscriptions
    static let weeklyPass  = "com.nagrom.roadtrip.weekly"
    static let monthlyPass = "com.nagrom.roadtrip.monthly"

    // Consumables
    static let rounds3  = "com.nagrom.roadtrip.rounds.3"
    static let rounds10 = "com.nagrom.roadtrip.rounds.10"

    static let subscriptionIDs: Set<String> = [weeklyPass, monthlyPass]
    static let consumableIDs: Set<String>   = [rounds3, rounds10]
    static let allProductIDs: Set<String>   = subscriptionIDs.union(consumableIDs)

    /// How many rounds each consumable grants
    static func roundsForProduct(_ id: String) -> Int {
        switch id {
        case rounds3:  return 3
        case rounds10: return 10
        default:       return 0
        }
    }
}
```

### 2.2 `Services/Store/StoreService.swift` — StoreKit 2 Manager

This is the core purchasing engine. It uses StoreKit 2's async/await APIs (requires iOS 15+).

```swift
import StoreKit
import Foundation

@MainActor
class StoreService: ObservableObject {
    static let shared = StoreService()

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedSubscriptionIDs: Set<String> = []
    @Published private(set) var isSubscribed = false

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
            products = try await Product.products(for: StoreProducts.allProductIDs)
                .sorted { $0.price < $1.price }
        } catch {
            print("[Store] Failed to load products: \(error)")
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async throws -> Bool {
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
            // Ask-to-Buy or SCA — transaction will arrive later
            return false

        @unknown default:
            return false
        }
    }

    // MARK: - Restore Purchases

    func restorePurchases() async {
        try? await AppStore.sync()
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
    }

    // MARK: - Active Subscription Tier

    var activeSubscription: String? {
        // Prefer monthly over weekly if both somehow active
        if purchasedSubscriptionIDs.contains(StoreProducts.monthlyPass) {
            return StoreProducts.monthlyPass
        }
        if purchasedSubscriptionIDs.contains(StoreProducts.weeklyPass) {
            return StoreProducts.weeklyPass
        }
        return nil
    }

    var roundsPerPeriod: Int {
        switch activeSubscription {
        case StoreProducts.weeklyPass:  return 5
        case StoreProducts.monthlyPass: return 10
        default:                        return 0
        }
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                if let transaction = try? self.checkVerified(result) {
                    await self.handleTransaction(transaction)
                    await transaction.finish()
                }
            }
        }
    }

    private func handleTransaction(_ transaction: Transaction) async {
        if StoreProducts.consumableIDs.contains(transaction.productID) {
            let rounds = StoreProducts.roundsForProduct(transaction.productID)
            RoundTracker.shared.addPurchasedRounds(rounds)
        }
        await updateSubscriptionStatus()
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let safe):       return safe
        }
    }
}
```

### 2.3 `Services/Store/RoundTracker.swift` — Round Budget Logic

This is where the free-round, subscription-round, and purchased-round accounting lives.

```swift
import Foundation

@MainActor
class RoundTracker: ObservableObject {
    static let shared = RoundTracker()

    private let defaults = UserDefaults.standard

    // Keys
    private let kFreeRoundUsed       = "rt_freeRoundUsed"
    private let kPurchasedRounds     = "rt_purchasedRounds"
    private let kSubscriptionRounds  = "rt_subscriptionRoundsUsed"
    private let kPeriodStartDate     = "rt_periodStartDate"

    @Published private(set) var canPlayRound = true

    private init() { refreshCanPlay() }

    // MARK: - Free Round

    var hasFreeRound: Bool {
        !defaults.bool(forKey: kFreeRoundUsed)
    }

    func consumeFreeRound() {
        defaults.set(true, forKey: kFreeRoundUsed)
        refreshCanPlay()
    }

    // MARK: - Purchased Round Packs (consumable)

    var purchasedRoundsRemaining: Int {
        defaults.integer(forKey: kPurchasedRounds)
    }

    func addPurchasedRounds(_ count: Int) {
        let current = defaults.integer(forKey: kPurchasedRounds)
        defaults.set(current + count, forKey: kPurchasedRounds)
        refreshCanPlay()
    }

    func consumePurchasedRound() {
        let current = defaults.integer(forKey: kPurchasedRounds)
        if current > 0 {
            defaults.set(current - 1, forKey: kPurchasedRounds)
        }
        refreshCanPlay()
    }

    // MARK: - Subscription Rounds

    /// Rounds used in the current subscription billing period.
    var subscriptionRoundsUsed: Int {
        resetPeriodIfNeeded()
        return defaults.integer(forKey: kSubscriptionRounds)
    }

    var subscriptionRoundsRemaining: Int {
        let limit = StoreService.shared.roundsPerPeriod
        return max(0, limit - subscriptionRoundsUsed)
    }

    func consumeSubscriptionRound() {
        resetPeriodIfNeeded()
        let used = defaults.integer(forKey: kSubscriptionRounds)
        defaults.set(used + 1, forKey: kSubscriptionRounds)
        refreshCanPlay()
    }

    // MARK: - Period Reset

    /// Resets the subscription round counter when a new billing period starts.
    /// Uses the transaction's original purchase date to determine period boundaries.
    private func resetPeriodIfNeeded() {
        guard StoreService.shared.isSubscribed else { return }

        let lastReset = defaults.object(forKey: kPeriodStartDate) as? Date ?? .distantPast
        let periodLength: TimeInterval

        if StoreService.shared.activeSubscription == StoreProducts.weeklyPass {
            periodLength = 7 * 24 * 3600  // 1 week
        } else {
            periodLength = 30 * 24 * 3600 // ~1 month
        }

        if Date().timeIntervalSince(lastReset) >= periodLength {
            defaults.set(0, forKey: kSubscriptionRounds)
            defaults.set(Date(), forKey: kPeriodStartDate)
        }
    }

    // MARK: - Unified Check

    /// The order of consumption priority:
    /// 1. Free round (if available)
    /// 2. Subscription rounds (if subscribed and rounds remain)
    /// 3. Purchased round packs
    func consumeOneRound() -> Bool {
        if hasFreeRound {
            consumeFreeRound()
            return true
        }
        if StoreService.shared.isSubscribed && subscriptionRoundsRemaining > 0 {
            consumeSubscriptionRound()
            return true
        }
        if purchasedRoundsRemaining > 0 {
            consumePurchasedRound()
            return true
        }
        return false
    }

    func refreshCanPlay() {
        canPlayRound = hasFreeRound
            || (StoreService.shared.isSubscribed && subscriptionRoundsRemaining > 0)
            || purchasedRoundsRemaining > 0
    }

    // MARK: - Summary for UI

    var statusSummary: String {
        var parts: [String] = []
        if hasFreeRound { parts.append("1 free round") }
        if StoreService.shared.isSubscribed {
            parts.append("\(subscriptionRoundsRemaining) subscription rounds")
        }
        if purchasedRoundsRemaining > 0 {
            parts.append("\(purchasedRoundsRemaining) purchased rounds")
        }
        return parts.isEmpty ? "No rounds available" : parts.joined(separator: " + ")
    }
}
```

### 2.4 `iPhone/PaywallViewController.swift` — Purchase UI

A UIKit view controller presented when the user tries to start a round but has none remaining. Should display:

- Current round balance (free / subscription / purchased)
- Subscription options (Weekly $4.99, Monthly $12.99) with "Subscribe" buttons
- Round pack options (3 for $2.99, 10 for $9.99) with "Buy" buttons
- "Restore Purchases" link at the bottom
- Dismiss/close button

Use the existing neon/retro theme from `IPhoneViewController` for visual consistency.

---

## Part 3: Integration Points in Existing Code

### 3.1 Gate Round Start in `RealtimeGameCoordinator`

The key interception point is when the LLM calls `report_score` at question 1 of a new round — this is when a new round effectively "starts." But a better UX is to check **before connecting** to the Realtime API (which costs money even if the user can't play).

**In `RealtimeGameCoordinator.startNewGame()`** — add a pre-flight check:

```swift
func startNewGame() {
    // Check round budget BEFORE connecting to OpenAI
    guard RoundTracker.shared.canPlayRound else {
        // Present paywall instead of starting game
        NotificationCenter.default.post(name: .showPaywall, object: nil)
        return
    }

    // Consume the round upfront
    let consumed = RoundTracker.shared.consumeOneRound()
    guard consumed else { return }

    // ... existing connection logic ...
}
```

Apply the same guard to `resumeGame()` and `startNewGameWithConfig()`.

### 3.2 Multi-Round Sessions

The current game flow allows playing multiple rounds in a single session (the LLM asks "want to keep going?" after each round). Each new round within a session also needs to consume a round credit.

**In `RealtimeGameCoordinator.handleReportScore()`** — when a new round starts (detected by `currentQuestionIndex == 0` after incrementing `currentRoundNumber`), consume another round:

```swift
// When round number increments and it's question 1:
if isNewRound {
    guard RoundTracker.shared.consumeOneRound() else {
        // Tell LLM to end the game — user is out of rounds
        sendFunctionResult(callId: callId, result: """
        {"error": "ROUND_LIMIT_REACHED",
         "message": "Player has used all available rounds. End the game now."}
        """)
        return
    }
}
```

### 3.3 Update `SystemPromptBuilder`

Add round-awareness to the system prompt so the LLM knows about limits:

```
The player has {N} rounds remaining. After each round, if they have 0 rounds
remaining, you MUST end the game by calling end_game. Do NOT ask if they want
to continue — tell them they've used all their rounds for now and suggest
upgrading their plan.
```

### 3.4 CarPlay Home Screen

**In `CarPlayCoordinator.buildHomeTemplate()`** — show round balance on the home screen. If no rounds remain, change "Start New Game" to "Get More Rounds" which opens the iPhone paywall.

### 3.5 Initialize StoreService Early

**In `AppDelegate.swift`** or at the top of `SceneDelegate.scene(_:willConnectTo:)`:

```swift
_ = StoreService.shared  // Starts transaction listener immediately
```

---

## Part 4: Supabase Changes

### 4.1 New Database Table: `subscriptions`

Add a new migration file `supabase/migrations/002_subscriptions.sql`:

```sql
-- Tracks user subscription state and round balances
CREATE TABLE IF NOT EXISTS subscriptions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    product_id TEXT,                          -- e.g. 'com.nagrom.roadtrip.monthly'
    status TEXT DEFAULT 'none',               -- 'active', 'expired', 'cancelled', 'none'
    original_transaction_id TEXT,
    current_period_start TIMESTAMPTZ,
    current_period_end TIMESTAMPTZ,
    purchased_rounds INT DEFAULT 0,           -- consumable round balance
    subscription_rounds_used INT DEFAULT 0,   -- rounds used this period
    free_round_used BOOLEAN DEFAULT FALSE,
    rounds_played_total INT DEFAULT 0,
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id)
);

ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own subscription"
    ON subscriptions FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can update own subscription"
    ON subscriptions FOR UPDATE
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own subscription"
    ON subscriptions FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Service role (edge functions) has full access via default
```

### 4.2 New Edge Function: `verify-receipt` (Optional Server-Side Validation)

For production, you should validate receipts server-side to prevent fraud. Create `supabase/functions/verify-receipt/index.ts`:

This function would:
1. Receive the StoreKit 2 `Transaction.jsonRepresentation` from the app
2. Verify the JWS signature using Apple's public key
3. Update the `subscriptions` table with the verified entitlement
4. Return the updated round balance

For MVP, client-side StoreKit 2 verification (which is cryptographically signed on-device) is sufficient. Add server-side validation later.

### 4.3 New Edge Function: `apple-server-notification` (Webhook)

If you set up App Store Server Notifications (recommended), create `supabase/functions/apple-server-notification/index.ts` to handle events like `DID_RENEW`, `EXPIRED`, `REFUND`, `REVOKE`, etc.

This keeps the `subscriptions` table in sync even when the user hasn't opened the app.

---

## Part 5: Implementation Order

**Phase 1 — Core Purchase Flow (ship first)**
1. Create `StoreProducts.swift`, `StoreService.swift`, `RoundTracker.swift`
2. Create the StoreKit configuration file for testing
3. Add the round gate in `RealtimeGameCoordinator.startNewGame()`
4. Build `PaywallViewController` with purchase buttons
5. Test in Simulator with StoreKit config file
6. Configure products in App Store Connect

**Phase 2 — Multi-Round & Polish**
7. Add per-round consumption in `handleReportScore()` for multi-round sessions
8. Update `SystemPromptBuilder` with round limits
9. Update CarPlay home screen to show round balance
10. Add "Restore Purchases" to settings/account screen
11. Handle edge cases (subscription expires mid-game, etc.)

**Phase 3 — Server-Side Sync**
12. Add `subscriptions` table to Supabase
13. Build `verify-receipt` edge function
14. Sync round balance between device and server (for multi-device users)
15. Build `apple-server-notification` webhook

---

## Part 6: Key Design Decisions

**"Round" = one 5-question standard round or one lightning round.** Lightning rounds (triggered every 4 standard rounds) should also consume a round credit, since they use API resources.

**Consumption priority:** Free round → Subscription rounds → Purchased packs. This gives the best UX — free users get hooked, subscribers use their allocation first, and purchased packs serve as overflow.

**Period reset:** The subscription round counter resets when StoreKit reports a new transaction for the same product (indicating renewal). This is more accurate than calendar-based calculation.

**Offline play:** StoreKit 2 caches entitlements on-device, so subscription checks work offline. Round balance in UserDefaults also works offline. Server sync happens when connectivity returns.

**Grace period:** If a subscription lapses (billing retry), the app should still allow play for Apple's grace period (typically 6-16 days). StoreKit 2 handles this — the entitlement remains valid during retry.

**Free round tied to device AND user:** Store the free-round flag in both UserDefaults (device) and Supabase (user). Check both — if either is consumed, the free round is gone. This prevents abuse by signing out/in or reinstalling.
