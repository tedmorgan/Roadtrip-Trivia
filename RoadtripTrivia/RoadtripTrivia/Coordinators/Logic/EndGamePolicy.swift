import Foundation

/// Pure decision logic for the `end_game` tool call.
///
/// The AI sometimes calls `end_game` when it shouldn't:
/// - Mid-round, when rounds are still available (regression in 7.log).
/// - During the lightning-timer race window, just after the timer
///   expired with rounds remaining.
/// - During the no-rounds-left farewell flow, where the app already
///   owns teardown and an immediate end would chop off the goodbye.
///
/// And conversely, the AI sometimes ignores the player's explicit
/// "no, let's end the game" (regression in 5.log / 6.log) and the app
/// must override.
///
/// This decider produces an action; the coordinator does the I/O.
public enum EndGameAction: Equatable {
    /// Acknowledge the call but defer teardown to the app's silence
    /// timer. Used when `pendingNoRoundsEnd` is in progress — we do
    /// NOT want to interrupt the farewell speech.
    case deferDuringFarewell

    /// Reject because the lightning timer just expired with rounds
    /// remaining. Tell the AI to move to the next round; do NOT ask
    /// the player to confirm (this is an automatic race-fix).
    case rejectLightningRace

    /// Reject because rounds remain mid-round. Tell the AI to ask the
    /// player whether they want to continue or stop. A subsequent
    /// `end_game` will be honored as the player's confirmation.
    case rejectAndAskForConfirmation

    /// Honor the call. Tear down the session normally.
    case honor
}

public enum EndGamePolicy {

    /// Decide what to do when the AI calls `end_game`.
    ///
    /// - Parameters:
    ///   - pendingNoRoundsEnd: true if the app's no-rounds farewell
    ///     chain is currently driving the conversation.
    ///   - sessionAlive: true if we still have a live game session.
    ///   - canPlayRound: true if `RoundTracker` has rounds available.
    ///   - lightningExpiredWithRoundsRemainingSecondsAgo: seconds
    ///     since the lightning timer expired with rounds left, or
    ///     `.infinity` if it hasn't expired this way recently.
    ///   - lightningExpiryRaceWindow: how long after such an expiry
    ///     we treat an `end_game` as a race-fix. Default 10 s.
    ///   - isLightningRound: true if currently in lightning round.
    ///   - roundAnswered: number of questions answered this round.
    ///   - endGameConfirmationPending: true if we already asked the
    ///     player to confirm via a prior rejection. A subsequent
    ///     `end_game` is honored as the player's confirmation.
    ///   - playerRequestedEndGame: true if input transcription showed
    ///     the player explicitly chose to stop. We must honor.
    public static func decide(
        pendingNoRoundsEnd: Bool,
        sessionAlive: Bool,
        canPlayRound: Bool,
        lightningExpiredWithRoundsRemainingSecondsAgo: TimeInterval,
        lightningExpiryRaceWindow: TimeInterval = 10,
        isLightningRound: Bool,
        roundAnswered: Int,
        endGameConfirmationPending: Bool,
        playerRequestedEndGame: Bool
    ) -> EndGameAction {
        // (1) Farewell flow always wins. Even if other conditions look
        // like a race or a missed-rounds case, the app is already
        // tearing down — defer.
        if pendingNoRoundsEnd {
            return .deferDuringFarewell
        }

        // (2) Player explicitly said end. Honor unconditionally so the
        // host can't keep asking "are you sure?" after a clear no.
        if playerRequestedEndGame {
            return .honor
        }

        // (3) Lightning-timer race window — auto-reject without asking
        // the player. The AI queued end_game before it processed our
        // "move to next round" instruction.
        if sessionAlive,
           canPlayRound,
           lightningExpiredWithRoundsRemainingSecondsAgo < lightningExpiryRaceWindow {
            return .rejectLightningRace
        }

        // (4) Broader guard: rounds remain mid-round. Ask the player
        // to confirm. If we already asked, this is the confirmation
        // and we honor.
        let isCompletedStandardRound = !isLightningRound && roundAnswered >= 5
        if sessionAlive,
           canPlayRound,
           !isCompletedStandardRound,
           !endGameConfirmationPending {
            return .rejectAndAskForConfirmation
        }

        // (5) Honor. Either no rounds remain, or the player has
        // confirmed via a second end_game, or we just finished a
        // standard round.
        return .honor
    }
}
