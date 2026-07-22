import Foundation

/// Typed struct for the `report_score` tool result. Only the five
/// fields the AI actively references in its speech are included —
/// ballast fields (acknowledged, totalCorrect, totalAnswered,
/// roundCorrect, roundPoints, roundQuestionIndex,
/// hintsRemainingThisRound, challengesRemainingThisRound) were removed
/// to reduce per-turn token cost. The app enforces hint/challenge
/// limits independently, and the AI never quotes per-round stats.
///
/// The coordinator constructs a `ReportScoreResult`, then calls
/// `.toDictionary()` to get the `[String: Any]` for submission.
public struct ReportScoreResult {
    public let isCorrect: Bool
    /// The authoritative correct answer for this question. The AI MUST
    /// use this to announce the answer when the player is wrong —
    /// it cannot be expected to remember from the question read.
    public let correctAnswer: String
    public let totalPoints: Int
    /// Post-consumption count from `RoundTracker.shared`. The AI uses
    /// this as the authoritative remaining-rounds number.
    public let roundsRemaining: Int
    /// Explicit instruction text from `ReportScoreActionPolicy`.
    public let nextAction: String

    public init(
        isCorrect: Bool,
        correctAnswer: String,
        totalPoints: Int,
        roundsRemaining: Int,
        nextAction: String
    ) {
        self.isCorrect = isCorrect
        self.correctAnswer = correctAnswer
        self.totalPoints = totalPoints
        self.roundsRemaining = roundsRemaining
        self.nextAction = nextAction
    }

    /// Converts to the `[String: Any]` dictionary the coordinator
    /// submits as the tool result. This is the ONLY place that maps
    /// struct fields to dictionary keys — any key/value mismatch is
    /// caught by tests against `requiredKeys`.
    public func toDictionary() -> [String: Any] {
        [
            "isCorrect": isCorrect,
            "correctAnswer": correctAnswer,
            "totalPoints": totalPoints,
            "roundsRemaining": roundsRemaining,
            "nextAction": nextAction
        ]
    }
}

/// Defines the required keys that EVERY `report_score` tool result
/// must include. Used by unit tests to verify that `toDictionary()`
/// produces a complete result.
public enum ReportScoreResultContract {

    public static let requiredKeys: Set<String> = [
        "isCorrect",
        "correctAnswer",
        "totalPoints",
        "roundsRemaining",
        "nextAction"
    ]

    public static func missingKeys(in result: [String: Any]) -> Set<String> {
        requiredKeys.subtracting(result.keys)
    }

    public static func isValid(_ result: [String: Any]) -> Bool {
        missingKeys(in: result).isEmpty
    }
}
