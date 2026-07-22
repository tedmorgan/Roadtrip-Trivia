import Foundation

/// Composes the exact round-intro announcement the host must read when a new
/// round (or lightning round) starts.
///
/// Why this exists: lightning rounds repeatedly started without being
/// announced (or were announced for normal rounds), and categories were
/// narrated inconsistently. Round format is app-owned state; the app now
/// composes the announcement and the model reads it verbatim before the
/// question.
enum RoundIntroComposer {

    static func compose(
        roundNumber: Int,
        category: String,
        isLightning: Bool,
        locationLabel: String?
    ) -> String {
        if isLightning {
            return "This is a Lightning Round! Two minutes on the clock, rapid fire — Round \(roundNumber), category: \(category). Ready?"
        }
        if let location = locationLabel, !location.isEmpty {
            return "Round \(roundNumber), coming to you from \(location) — the category is \(category)!"
        }
        return "Round \(roundNumber) — the category is \(category)!"
    }
}
