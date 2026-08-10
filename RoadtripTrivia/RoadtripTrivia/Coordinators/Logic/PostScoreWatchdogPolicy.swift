import Foundation

/// Pure decision logic for the post-score silence watchdog.
///
/// Background: after the player answers and the app calls `report_score`,
/// we expect the AI to play a brief reaction audio and then call
/// `get_next_question`. If neither happens, we want to nudge it without
/// (a) interrupting an in-progress reaction, (b) double-driving when the
/// no-rounds-left farewell flow already owns nudging, or (c) firing
/// during a brief audio gap between sub-turns of a multi-part reaction.
///
/// The actual scheduling and I/O still live in
/// `RealtimeGameCoordinator`. This type only decides *what* to do when
/// the timer fires, given a snapshot of the relevant state. Extracting
/// the decision makes it unit-testable in isolation — every regression
/// in this area we've shipped became a one-liner test.

public enum HostPhase: Equatable {
    /// AI is currently streaming audio — host speech in progress.
    case speaking
    /// AI has finished its turn and we're waiting for player audio.
    case listening
    /// Any other phase (idle, connecting, paused, gameOver, ...).
    case other
}

public enum PostScoreReason: String, Equatable {
    /// Initial 5 s window after `report_score` — AI hasn't produced any
    /// audio at all yet. A genuine wedged turn requires `responseCancel`.
    case armed = "post-score-armed"
    /// Continuation window after the AI's brief reaction audio
    /// completed but no `get_next_question` followed. We must NOT
    /// `responseCancel` — that would chop off the AI's next sub-turn
    /// (e.g. the wrong-answer explanation).
    case continuation = "post-score-continuation"
}

public enum PostScoreAction: Equatable {
    /// Do nothing — caller should drop the timer.
    case skip(reason: String)
    /// Re-arm the timer with the same reason and timeout. Caller should
    /// reschedule.
    case reArm(reason: String)
    /// Send a `responseCreate(nudge)` only. No
    /// escalation arm.
    case fireSoft
    /// Send a `responseCreate(nudge)` AND arm the escalation watchdog.
    /// Note: this used to also send `responseCancel` ("[stop]"), but in
    /// Gemini any text input already interrupts the current generation,
    /// and the explicit stop orphaned in-flight function calls
    /// (toolCallCancellation → re-grade loop → server close).
    case fireHard
}

public enum PostScoreWatchdogPolicy {

    /// Decides what the post-score watchdog should do when its timer
    /// fires.
    ///
    /// - Parameters:
    ///   - sessionAlive: true if we still have a live game session.
    ///     A torn-down session means there's nothing to nudge.
    ///   - pendingNoRoundsEnd: true if the no-rounds-left farewell
    ///     flow is currently driving the conversation. That flow owns
    ///     all nudging — we must not double-drive.
    ///   - phase: the host's current phase. If `.speaking`, the AI is
    ///     already producing audio; we must not interrupt it.
    ///   - secondsSinceLastAudioDelta: time since the AI's most recent
    ///     audio chunk. Even when phase is `.listening`, recent audio
    ///     means the AI is between sub-turns and will likely resume.
    ///   - reason: which post-score window we're in. Continuation is
    ///     soft (no cancel); armed is hard (cancel + escalate).
    ///   - secondsSinceLastToolEvent: time since the most recent tool
    ///     call arrived or tool result was submitted. After a tool
    ///     response, Gemini is silently composing its next turn for up
    ///     to several seconds — no audio yet, but very much alive.
    ///     Nudging during this window is what caused the 2026-06-11
    ///     cancel storms: any `realtimeInput.text` interrupts the
    ///     in-flight generation, orphans its pending function call
    ///     (`toolCallCancellation`), the model retries `report_score`,
    ///     the watchdog re-fires, and the server eventually closes the
    ///     session (1001).
    ///   - recentAudioWindowSeconds: duration of the "recent audio"
    ///     window. Default 2.0; exposed for testing.
    ///   - toolQuietWindowSeconds: duration of the "recent tool
    ///     activity" window. Default 12.0; exposed for testing.
    ///     Raised from 6.0 -> 12.0 on 2026-06-25: with context compression
    ///     effectively disabled (full context retained), Gemini's silent
    ///     post-`report_score` composition window stretched to ~7-12s. The
    ///     6s guard let the watchdog fire at ~7.3s while the model was still
    ///     composing its `get_next_question`; the nudge orphaned that
    ///     in-flight call (toolCallCancellation), the model re-scored, and
    ///     the game froze (debug-f3b222.log 2026-06-25, R2Q2).
    ///
    ///     IMPORTANT: this guard applies to the `.armed` window ONLY. The
    ///     whole point of the guard is to avoid interrupting a response that
    ///     is still being silently composed — a risk that exists only when
    ///     NO audio has been produced since `report_score` (i.e. `.armed`).
    ///     The `.continuation` window is reached exclusively AFTER
    ///     `responseAudioDone` — the verdict response has already completed,
    ///     so there is no in-flight generation to orphan. Applying the 12s
    ///     gate there just manufactured ~11-14s of dead air on every stalled
    ///     verdict where the model forgot to chain `get_next_question`
    ///     (debug-f3b222.log 2026-07-31, R2Q3→Q4 / R3Q3→Q4 / R3Q4→Q5).
    public static func decide(
        sessionAlive: Bool,
        pendingNoRoundsEnd: Bool,
        phase: HostPhase,
        secondsSinceLastAudioDelta: TimeInterval,
        reason: PostScoreReason,
        secondsSinceLastToolEvent: TimeInterval = .infinity,
        recentAudioWindowSeconds: TimeInterval = 2.0,
        toolQuietWindowSeconds: TimeInterval = 12.0
    ) -> PostScoreAction {
        guard sessionAlive else {
            return .skip(reason: "session ended")
        }
        guard !pendingNoRoundsEnd else {
            return .skip(reason: "no-rounds-end owns nudging")
        }
        if phase == .speaking {
            return .reArm(reason: "host speaking")
        }
        if secondsSinceLastAudioDelta < recentAudioWindowSeconds {
            return .reArm(reason: "recent host audio (\(String(format: "%.2f", secondsSinceLastAudioDelta))s)")
        }
        // Tool-quiet guard: only meaningful in the `.armed` window, where the
        // model may still be silently composing its verdict+get_next response
        // and a nudge would orphan the in-flight call (the 2026-06-25 freeze).
        // In `.continuation` we are here only because `responseAudioDone`
        // already fired — the verdict turn completed, so there is nothing
        // in-flight to protect and blocking here only adds dead air.
        if reason == .armed, secondsSinceLastToolEvent < toolQuietWindowSeconds {
            return .reArm(reason: "recent tool activity (\(String(format: "%.2f", secondsSinceLastToolEvent))s) — model is composing")
        }
        switch reason {
        case .continuation: return .fireSoft
        case .armed:        return .fireHard
        }
    }
}
