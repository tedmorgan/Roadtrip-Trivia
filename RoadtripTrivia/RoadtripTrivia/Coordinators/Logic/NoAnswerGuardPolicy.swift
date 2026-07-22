import Foundation

/// Pure decision logic for rejecting `report_score` calls where the model
/// invented an answer for a player who never spoke.
///
/// Background (2026-06-12 drive test): whenever the player paused ~2s to
/// think, Gemini's VAD committed the silence/road noise as a "turn", and the
/// model — required by the prompt to score "the instant they finish" —
/// fabricated a score, usually `playerAnswer="skip"`. The app then played
/// the wrong-answer gong and the verdict line revealed the correct answer.
/// This happened on effectively every question the player didn't answer
/// instantly.
///
/// The app knows whether the player actually said anything: input
/// transcription events arrive for all real player speech. So a plain
/// answer score with NO player speech since the question was served is
/// fabricated, and placeholder answers ("no answer", "silence", …) are
/// fabricated regardless of transcripts.
///
/// Fail-open design: transcript corroboration denies at most `maxDenials`
/// times per question, so a broken transcription stream degrades to the old
/// behavior instead of deadlocking the game. Placeholder answers are denied
/// without a cap — waiting forever on a genuinely silent player is correct.
public enum NoAnswerGuardPolicy {

    public enum Verdict: Equatable {
        case accept
        /// Reject the score; the tool result should tell the model to wait
        /// for a real answer. `reason` is for the instruction text and logs.
        case deny(reason: String)
    }

    /// Placeholder strings models emit when scoring a silent player.
    /// Compared against the normalized (lowercased, trimmed of punctuation)
    /// player answer.
    static let placeholderAnswers: Set<String> = [
        "", "no answer", "no response", "none", "n a", "silence", "silent",
        "nothing", "timeout", "time out", "no reply", "unintelligible",
        "inaudible", "did not answer", "didn t answer", "player did not answer"
    ]

    public static func decide(
        playerAnswer: String,
        isHint: Bool,
        isChallenge: Bool,
        isScoringRevision: Bool,
        isLightning: Bool,
        playerSpokeSinceServe: Bool,
        priorDenials: Int,
        maxDenials: Int = 2
    ) -> Verdict {
        // Detours and re-grades are themselves triggered by player speech
        // (or by the host correcting itself) — never block them. Lightning
        // is exempt: its pacing tolerates aggressive scoring and a denial
        // loop there would burn the timer.
        if isHint || isChallenge || isScoringRevision || isLightning {
            return .accept
        }

        if placeholderAnswers.contains(normalize(playerAnswer)) {
            return .deny(reason: "placeholder answer \"\(playerAnswer)\"")
        }

        if !playerSpokeSinceServe && priorDenials < maxDenials {
            return .deny(reason: "no player speech since the question was read")
        }

        return .accept
    }

    /// Decides whether the player actually had a chance to answer AND spoke.
    ///
    /// The player can only answer once the question has finished being read
    /// and the mic is open — call that the "answer window". Measuring speech
    /// from the moment the question was *served* is wrong: the mic is muted
    /// for the entire ~15s the host reads (so the host's own audio isn't
    /// captured), and when the mic finally opens the pre-roll flush replays a
    /// fraction of a second of buffered audio — usually the host's trailing
    /// voice or road noise — which the model transcribes as a phantom
    /// "player answer" (2026-07-21 R2Q5: the game chimed and moved on ~1.5s
    /// after the mic opened, before the player could speak).
    ///
    /// So a transcript only counts as a real answer if it lands at least
    /// `prerollGrace` after the answer window opened.
    ///
    /// - Returns: `true` if the player is judged to have given a real answer.
    ///   When the window hasn't opened yet (host still reading), no answer is
    ///   possible → `false`. If neither timestamp is tracked, fail open
    ///   (`true`) so a telemetry gap can't deadlock the game.
    public static func playerProvidedAnswer(
        lastPlayerSpeechAt: Date?,
        answerWindowOpenedAt: Date?,
        questionServedAt: Date?,
        prerollGrace: TimeInterval = 1.0
    ) -> Bool {
        if let windowStart = answerWindowOpenedAt {
            guard let spoke = lastPlayerSpeechAt else { return false }
            return spoke >= windowStart.addingTimeInterval(prerollGrace)
        }
        // Window never opened. If we at least know the question was served,
        // the host is still reading (or just finished) — no legitimate answer
        // is possible yet.
        if questionServedAt != nil { return false }
        // No timing tracked at all — degrade to the old fail-open behavior.
        return true
    }

    /// Lowercase, collapse punctuation/whitespace runs to single spaces,
    /// trim. "(No answer)" → "no answer".
    static func normalize(_ answer: String) -> String {
        let lowered = answer.lowercased()
        let parts = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
