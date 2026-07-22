import Foundation

/// Pure text classifier for player input transcripts.
///
/// The Gemini Live API streams transcripts of the player's speech as
/// `responseAudioTranscriptDelta` events. The coordinator uses these
/// to enforce app-side rules the AI sometimes violates — most
/// importantly, "the player asked to stop playing" (regression fixed
/// after `debug-f3b222 5.log` and `6.log`, where the host kept asking
/// "are you sure?" after the player clearly said no).
///
/// This classifier is tone-deaf to context (between-rounds vs.
/// mid-round) — that gating is the coordinator's job. The classifier
/// only answers: "does this snippet of text plausibly mean end-game?"
public enum PlayerIntentClassifier {

    public enum EndGameSignal: Equatable {
        /// No end-game intent detected.
        case none

        /// A strong phrase like "let's end the game", "stop playing",
        /// "quit". Always honored regardless of context.
        case explicit

        /// A bare "no"/"nope"/"nah". Only meaningful in a
        /// between-rounds confirmation window (where the host just
        /// asked "want to keep going?"). Caller must gate on context.
        case softNo
    }

    /// Classify a single transcript delta. The coordinator typically
    /// calls this on every delta and acts only when the result is
    /// non-`.none` AND the context is appropriate (between-rounds
    /// stop window, or already-pending confirmation).
    public static func classifyEndGame(_ text: String) -> EndGameSignal {
        let lower = text.lowercased()
        let normalized = lower
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "!", with: " ")
            .replacingOccurrences(of: "?", with: " ")
        let padded = " \(normalized) "

        // Unambiguous quit phrases. These never occur as trivia answers, so the
        // coordinator honors them at ANY time, including mid-round.
        if padded.contains(" end game ")
            || padded.contains(" end the game ")
            || padded.contains(" stop game ")
            || padded.contains(" stop the game ")
            || padded.contains(" stop playing ")
            || padded.contains(" quit ")
            || padded.contains(" done playing ")
            || padded.contains(" im done ")
            || padded.contains(" i quit ") {
            return .explicit
        }

        // Ambiguous "soft" declines. Meaningful only in the between-rounds
        // confirmation window — mid-round these are usually answers ("no", or
        // "no more hints"), so the coordinator ignores them there.
        if padded.contains(" no ")
            || padded.contains(" nope ")
            || padded.contains(" nah ")
            || padded.contains(" no more ") {
            return .softNo
        }

        return .none
    }

    /// Backwards-compatible boolean wrapper that matches the old
    /// `transcriptRequestsEndGame` API. Returns true for any
    /// non-`.none` signal — caller is responsible for context gating
    /// (the between-rounds stop window check).
    public static func transcriptRequestsEndGame(_ text: String) -> Bool {
        return classifyEndGame(text) != .none
    }
}
