import Foundation

/// Pure-logic contracts for the farewell end-game sequence.
///
/// Two failure modes have been observed in production:
///
/// 1. `debug-f3b222 5.log` (2026-05-07): `triggerInternalEndGame`
///    called `gameViewModel.transition(to: .gameOver)` BEFORE
///    `disconnect()`. The `.gameOver` transition triggered UI
///    observers that called `disconnect()` within 56ms, bypassing the
///    2.5s audio-drain grace period. Audio was cut off mid-farewell.
///    **Contract**: disconnect must happen before gameOver transition.
///
/// 2. `debug-f3b222 5.log` (2026-05-07): post-score silence watchdog
///    at 5.0s caused 5-second dead pauses between every question in
///    R3/R4. The threshold must be tight enough to avoid perceived lag.
///    **Contract (original)**: initial and continuation thresholds ≤ 3.5s.
///
///    REVISED 2026-06-11 (debug-f3b222 6.log freeze cascade): 3.5s fired
///    while Gemini was still silently composing a healthy verdict turn
///    (4-6s time-to-first-audio after a tool response is normal), and the
///    resulting nudge orphaned the in-flight function call and killed the
///    session. Dead air on healthy turns is now prevented by the
///    tool-quiet gate in `PostScoreWatchdogPolicy`, not by a tight
///    timeout, so the limits are 7.0s initial / 5.0s continuation.
///    A genuinely wedged turn surfacing at ~7.5s is the accepted cost of
///    never interrupting a healthy one.
public enum FarewellEndGamePolicy {

    /// Models the two phases of `triggerInternalEndGame`. The ordering
    /// contract is: cleanup → disconnect → session end → gameOver.
    public enum EndGameStep: Int, Comparable, CaseIterable {
        case cleanupState = 0
        case disconnectWebSocket = 1
        case endSession = 2
        case transitionToGameOver = 3

        public static func < (lhs: EndGameStep, rhs: EndGameStep) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Returns true if the disconnect step occurs before the gameOver
    /// transition in the provided step sequence.
    public static func isDisconnectBeforeGameOver(steps: [EndGameStep]) -> Bool {
        guard let disconnectIdx = steps.firstIndex(of: .disconnectWebSocket),
              let gameOverIdx = steps.firstIndex(of: .transitionToGameOver)
        else { return false }
        return disconnectIdx < gameOverIdx
    }

    /// Post-score silence watchdog thresholds. These are both the maximum
    /// values allowed AND the values the coordinator uses (it reads these
    /// constants directly — see `RealtimeGameCoordinator` — so the contract
    /// and the runtime behavior cannot drift apart again; on 2026-06-12 a
    /// divergence between the two crashed every CarPlay game start via the
    /// coordinator's init-time assert).
    public static let maxPostScoreInitialSilenceSeconds: Double = 7.0
    public static let maxPostScoreContinuationSilenceSeconds: Double = 5.0

    /// Validates that the given thresholds don't exceed the contract
    /// limits. Returns true if both are within bounds.
    public static func areThresholdsAcceptable(
        initialSilence: Double,
        continuationSilence: Double
    ) -> Bool {
        initialSilence <= maxPostScoreInitialSilenceSeconds &&
        continuationSilence <= maxPostScoreContinuationSilenceSeconds
    }
}
