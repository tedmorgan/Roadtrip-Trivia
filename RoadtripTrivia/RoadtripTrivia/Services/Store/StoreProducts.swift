import Foundation

/// Product identifiers matching App Store Connect configuration.
/// Subscription group: "Roadtrip Trivia Pass"
enum StoreProducts {

    // MARK: - Auto-Renewable Subscriptions

    static let weeklyPass  = "com.nagrom.roadtrip.weekly"
    static let monthlyPass = "com.nagrom.roadtrip.monthly"

    // MARK: - Consumable In-App Purchases

    static let rounds3  = "com.nagrom.roadtrip.rounds.3"
    static let rounds10 = "com.nagrom.roadtrip.rounds.10"

    // MARK: - Sets

    static let subscriptionIDs: Set<String> = [weeklyPass, monthlyPass]
    static let consumableIDs: Set<String>   = [rounds3, rounds10]
    static let allProductIDs: Set<String>   = subscriptionIDs.union(consumableIDs)

    // MARK: - Round Grants

    /// How many rounds a consumable product grants.
    static func roundsForProduct(_ id: String) -> Int {
        switch id {
        case rounds3:  return 3
        case rounds10: return 10
        default:       return 0
        }
    }

    /// Weekly subscribers get 5 rounds per period; monthly get 10.
    static func roundsPerPeriod(for productID: String) -> Int {
        switch productID {
        case weeklyPass:  return 5
        case monthlyPass: return 10
        default:          return 0
        }
    }
}
