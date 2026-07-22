import Foundation

/// Decides whether a server-side "interrupted" event (Gemini's VAD claims the
/// user started speaking) should be honored by killing local playback.
///
/// Why this exists: `serverContent.interrupted` fires from ANY audio the
/// server received recently — cabin noise, speaker echo picked up during the
/// brief open-mic windows, or stale audio still in the pipeline. Honoring
/// every one of these with `playerNode.stop()` is the root cause of the
/// "host cut off mid-sentence" family of regressions (the single most
/// reported issue across 20 builds — see debug-f3b222 logs from Apr–May 2026).
///
/// The rule: a barge-in is only real if WE were actually sending mic audio
/// (mic open) AND our own client-side energy detector heard voice-level audio
/// recently. Otherwise the event is noise/echo/stale and playback continues.
enum BargeInPolicy {

    enum Verdict: Equatable {
        /// Genuine user barge-in — stop playback, open the mic.
        case honor
        /// An utterance lock (farewell / must-finish speech) is active.
        case ignoreUtteranceLock
        /// Mic was muted client-side — no live audio reached the server,
        /// so the interruption must be stale or echo.
        case ignoreMicMuted
        /// Mic was open but we never measured voice-level energy locally —
        /// the server VAD tripped on noise.
        case ignoreNoLocalVoice
    }

    /// Window within which client-side voice energy corroborates a server
    /// barge-in. Generous enough to cover network + VAD latency.
    static let corroborationWindowSeconds: Double = 2.5

    static func decide(
        micMuted: Bool,
        utteranceLockActive: Bool,
        secondsSinceLocalVoice: Double?,
        corroborationWindow: Double = corroborationWindowSeconds
    ) -> Verdict {
        if utteranceLockActive { return .ignoreUtteranceLock }
        if micMuted { return .ignoreMicMuted }
        guard let since = secondsSinceLocalVoice, since <= corroborationWindow else {
            return .ignoreNoLocalVoice
        }
        return .honor
    }
}
