import Foundation

/// Pure decision logic for the question-read watchdog.
///
/// Background: when the app submits a question to the AI via
/// `submitResultImmediate(...)` we arm `questionReadWatchdog` to fire after
/// `questionReadTimeoutSeconds` (3 s by default). On fire we want to
/// distinguish three cases:
///
///   1. AI is actively reading the question — recent audio delta, no nudge
///      needed.
///   2. AI started a turn but stopped streaming without `responseAudioDone`
///      (`stuckSpeaking`) — the dead turn must be cleared (`responseCancel`)
///      before issuing a fresh `responseCreate`.
///   3. AI never started speaking — phase is `.listening`, the read got lost.
///      Soft `responseCreate` re-prompt is enough.
///
/// Failure modes that drove this extraction (all reproduced in
/// `Tests/RoadtripTriviaLogicTests/QuestionReadWatchdogPolicyTests.swift`):
///
///   • `debug-f3b222 3.log` (R1Q3, R2Q1, R3Q1, 2026-05-04): with a 1.5 s
///     silence threshold the watchdog fired with `silentSec` 2.65–2.9 s
///     during the AI's reaction-then-question turn, sent
///     `responseCancel + responseCreate`, and chopped off the host
///     mid-question. Threshold needed to be ≥ ~3 s so natural pauses don't
///     trigger a cancel.
///   • Farewell flow (no-rounds-left): an old QREAD scheduled before the
///     last question's `report_score` could fire while
///     `pendingNoRoundsEnd` was already driving the conversation, sending
///     a `responseCreate` that interrupted the farewell chain. The policy
///     must skip in that state.
///
/// This module owns ONLY the "what should the watchdog do?" decision.
/// Scheduling, cancel/create wire I/O, and phase transitions stay in
/// `RealtimeGameCoordinator`.

public enum QuestionReadPhase: Equatable {
    /// AI is currently streaming audio for some turn.
    case speaking
    /// AI has finished its turn and we're waiting for player audio.
    case listening
    /// Phases where firing this watchdog is never appropriate
    /// (`gameOver`, `connecting`, `idle`, `paused`, `resumePrompt`).
    case ineligible
    /// Anything else (e.g. `playing`, `waiting`, `showingResult`).
    case other
}

public enum QuestionReadAction: Equatable {
    /// Drop the watchdog with no further action.
    case skip(reason: String)
    /// Send a `responseCreate` re-prompt only. AI was idle but hasn't
    /// produced any audio for this turn — no in-flight turn to clear.
    case fireSoftNudge
    /// Send `responseCancel`, brief pause, then `responseCreate`. AI
    /// emitted some audio for the read then froze; the dead turn has to
    /// be cleared or Gemini ignores the new instruction.
    case fireStuckSpeakingRecovery
}

public enum QuestionReadWatchdogPolicy {

    /// Decide what the question-read watchdog should do at fire time.
    ///
    /// - Parameters:
    ///   - sessionAlive: true if the realtime session is still running.
    ///   - pendingNoRoundsEnd: true if the no-rounds-left farewell flow
    ///     currently owns the conversation. Firing here would interrupt
    ///     the farewell.
    ///   - phase: current host phase (UI-side mapping).
    ///   - secondsSinceLastAudioDelta: time since the AI's most recent
    ///     audio chunk. `.infinity` is allowed for "never streamed".
    ///   - silenceThreshold: minimum silence duration before we'll
    ///     consider firing. Caller passes
    ///     `questionReadSilenceThreshold` from the coordinator.
    public static func decide(
        sessionAlive: Bool,
        pendingNoRoundsEnd: Bool,
        phase: QuestionReadPhase,
        secondsSinceLastAudioDelta: TimeInterval,
        silenceThreshold: TimeInterval
    ) -> QuestionReadAction {
        guard sessionAlive else {
            return .skip(reason: "session ended")
        }
        guard !pendingNoRoundsEnd else {
            return .skip(reason: "no-rounds-end owns nudging")
        }
        if phase == .ineligible {
            return .skip(reason: "phase not eligible")
        }
        if secondsSinceLastAudioDelta < silenceThreshold {
            return .skip(reason: "AI still streaming audio (\(formatGap(secondsSinceLastAudioDelta))s)")
        }
        if phase == .speaking {
            return .fireStuckSpeakingRecovery
        }
        return .fireSoftNudge
    }

    private static func formatGap(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "∞" }
        return String(format: "%.2f", value)
    }
}
