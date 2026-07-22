import Foundation

/// Pure decision logic for what the AI should do *after* a `report_score`
/// tool call.
///
/// Background: every time the player answers, we score it via
/// `report_score` and return a tool result that includes a `nextAction`
/// instruction string. Three regimes exist:
///
///   1. Mid-round (Q1–Q4 of a standard round, or any lightning question):
///      brief reaction, then call `get_next_question`.
///   2. Round complete, more rounds still available: round summary, ask
///      whether to continue.
///   3. Round complete, no rounds left: app drives the farewell — AI
///      should acknowledge quietly and wait.
///
/// Why this is a separate type: in `debug-f3b222 3.log` (2026-05-04),
/// the AI hallucinated "no more rounds available" twice in one session:
///
///   • At R2 end with 1 round still available — the static system
///     prompt's "ROUND BUDGET: 2 rounds remaining after this one" gets
///     stale after consumption, and the `report_score` tool result
///     contained no explicit rounds-remaining counter. The AI tried to
///     reconstruct the count from the prompt and got it wrong.
///   • At R3 end with 3 rounds still available (after a mid-session
///     purchase). The system prompt never updates after a purchase, so
///     the AI's stale belief overrode the actual `RoundTracker` state.
///
/// The fix is twofold: include `roundsRemaining` (post-consumption) as
/// a field in the tool result, and make `nextAction` explicit about the
/// count and forbidden wording. This module owns ONLY the decision —
/// the coordinator is still responsible for assembling and submitting
/// the tool result.

public enum ReportScoreOutcome: Equatable {
    /// Standard mid-round question (Q1–Q4 of a standard round, or any
    /// lightning-round question). AI should give a brief reaction and
    /// call `get_next_question`.
    case midRound

    /// Round complete (Q5 of a standard round) and the player still
    /// has rounds available. AI should give a round summary, mention
    /// the remaining-rounds count, and ask whether to continue.
    case roundCompleteContinue(roundsLeft: Int)

    /// Round complete and no more rounds are available. The app will
    /// drive the farewell as a chunked sequence; the AI should
    /// acknowledge quietly and wait.
    case roundCompleteNoRoundsLeft
}

public enum ReportScoreActionPolicy {

    /// Decide what regime we're in based on the current question state.
    ///
    /// - Parameters:
    ///   - questionIndex: 1-based question number within the round (or
    ///     within the lightning round). Standard rounds end at 5.
    ///   - isLightningRound: lightning rounds never have a 5-question
    ///     completion boundary; they end on timer expiry instead.
    ///   - canPlayRound: dynamic check from `RoundTracker.shared` —
    ///     true if the player still has rounds available *after* the
    ///     current round was consumed.
    ///   - roundsLeftAfterScoring: post-consumption value of
    ///     `RoundTracker.shared.totalRoundsAvailable`. Should be ≥ 0.
    public static func decide(
        questionIndex: Int,
        isLightningRound: Bool,
        canPlayRound: Bool,
        roundsLeftAfterScoring: Int
    ) -> ReportScoreOutcome {
        let isRoundComplete = questionIndex >= 5 && !isLightningRound
        guard isRoundComplete else { return .midRound }
        if !canPlayRound {
            return .roundCompleteNoRoundsLeft
        }
        return .roundCompleteContinue(roundsLeft: max(0, roundsLeftAfterScoring))
    }

    /// The exact `nextAction` instruction text we want the AI to read
    /// in the `report_score` tool result. Wording is deliberately
    /// explicit about the rounds-remaining count and what NOT to say,
    /// to counter the hallucination patterns seen in production logs.
    public static func nextActionText(for outcome: ReportScoreOutcome) -> String {
        switch outcome {
        case .midRound:
            return "React in 1 sentence, then IMMEDIATELY call get_next_question. Do NOT ask if ready."

        case .roundCompleteContinue(let roundsLeft):
            let countPhrase = roundsLeft == 1
                ? "1 more round"
                : "\(roundsLeft) more rounds"
            return """
            Round complete. \(countPhrase) available. \
            Brief round summary, state \(countPhrase) left, ask if they want to continue. \
            Do NOT say "last round", "no more rounds", or imply rounds are exhausted. Do NOT call end_game.
            """

        case .roundCompleteNoRoundsLeft:
            return "LAST available round finished. App drives farewell — acknowledge quietly and wait. Do NOT call end_game. Do NOT call get_next_question. Do NOT ask if they want to play again."
        }
    }
}
