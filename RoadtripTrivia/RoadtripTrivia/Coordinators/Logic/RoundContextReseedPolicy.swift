import Foundation

/// Decides when to drop Gemini Live conversation history and reseed from
/// app-owned memory so later rounds do not re-bill the whole game.
///
/// In-round context stays on the live session (banter, this round's
/// questions, hints). Across rounds, score / categories / past results live
/// in the app and are injected as a compact GAME STATE snapshot.
public enum RoundContextReseedPolicy {

    /// True when the next serve is Q1 of round 2+ and that round has not
    /// already been reseeded. Round 1 keeps the intro in the same session.
    public static func shouldReseed(
        nextRoundNumber: Int,
        nextQuestionIndex: Int,
        lastReseededRound: Int?
    ) -> Bool {
        nextQuestionIndex == 1
            && nextRoundNumber > 1
            && lastReseededRound != nextRoundNumber
    }

    /// Spoken locally while the next round's session is resetting, so the
    /// player is not left in the 30s dead air from 2026-09-24 (Science →
    /// History) where the reseed itself is required to stay silent.
    /// Only after the previous answer has finished AND the new host has
    /// stayed quiet this long — a fast reseed must not talk over the verdict
    /// with the system voice (2026-09-27: the line played after every round).
    public static let roundBoundaryFiller = "Next round is coming right up."
    public static let roundBoundaryFillerDelaySeconds: TimeInterval = 4

    public static func shouldSpeakRoundBoundaryFiller(
        secondsSincePlaybackDrained: TimeInterval,
        hostHasSpokenSinceReseed: Bool
    ) -> Bool {
        !hostHasSpokenSinceReseed
            && secondsSincePlaybackDrained >= roundBoundaryFillerDelaySeconds
    }

    /// Tool-result instruction while the old session is being torn down.
    /// Must not invite the host to speak: the Build 45 Geography reseed left
    /// an 18s announce window where Gemini invented a fake Q1 that could
    /// not be scored.
    public static func bridgeInstruction(announce: String) -> String {
        "Do not speak. Do not announce the round. Do not read a question, greet, or recap. Wait silently. The next round (\(announce)) will start after a brief reset."
    }

    /// Announce on the *new* session after reseed. Always false: we no
    /// longer speak the announce on the old session.
    public static func shouldOmitAnnounce(
        roundNumber: Int,
        questionIndex: Int,
        lastReseededRound: Int?
    ) -> Bool {
        _ = (roundNumber, questionIndex, lastReseededRound)
        return false
    }

    /// First turn on the fresh session. Must not re-run setup. The tool
    /// result for Q1 includes `announce` — say that, then read Q1.
    public static func postReseedInstructions(roundNumber: Int, category: String) -> String {
        "Same game, Round \(roundNumber), category \(category). Call get_next_question NOW. After it returns, say the announce field VERBATIM, then the read field VERBATIM exactly once. Do not repeat the question number. Do NOT greet, do NOT re-ask setup, do NOT recap rules, and do NOT mention reconnecting or loading."
    }

    /// Compact past-round lines for the system prompt (not full transcripts).
    public static func pastRoundsSummary(
        rounds: [(roundNumber: Int, category: String, correct: Int, answered: Int)]
    ) -> String {
        guard !rounds.isEmpty else { return "None yet." }
        return rounds.map { round in
            "R\(round.roundNumber) \(round.category) \(round.correct)/\(round.answered)"
        }.joined(separator: "; ")
    }
}

/// Decides whether a host transcript is announcing a NEW lightning round.
/// The 2026-09-24 wrap-up spoke only "Lightning Round" after TIME IS UP,
/// which re-armed the 2:00 clock and then froze.
public enum LightningAnnouncementPolicy {

    public static func isNewLightningStart(transcript: String, lightningTimedOut: Bool) -> Bool {
        if lightningTimedOut { return false }
        let lower = transcript.lowercased()
        guard lower.contains("lightning") else { return false }
        if lower.contains("time is up") || lower.contains("time's up") || lower.contains("times up") {
            return false
        }
        if lower.contains("lightning over") || lower.contains("lightning is over") || lower.contains("round is over") {
            return false
        }
        if lower.contains("total up") { return false }
        if lower.contains("score now") && lower.contains("lightning") { return false }
        if lower.contains("tally") && lower.contains("score") { return false }
        if lower.contains("totaling") || lower.contains("totalling") { return false }
        if lower.contains("that was") && lower.contains("lightning") { return false }
        if lower.contains("amazing job") && lower.contains("lightning") { return false }
        if lower.contains("great job") && lower.contains("lightning") { return false }
        if lower.contains("lightning round") { return true }
        let startPhrases = [
            "jumping", "into the lightning", "into a lightning",
            "start the lightning", "begin the lightning", "starting the lightning",
            "here's the lightning", "here is the lightning", "here’s the lightning",
            "time for a lightning", "time for the lightning",
            "going into a lightning", "going into the lightning",
            "let's do a lightning", "lets do a lightning",
            "you're jumping", "you are jumping"
        ]
        return startPhrases.contains { lower.contains($0) }
    }

    public static func wrapUpLine(correct: Int, answered: Int) -> String {
        "Time is up. Lightning round over. You got \(correct) out of \(answered). Want to keep playing?"
    }

    /// Who speaks when the lightning clock hits zero.
    ///
    /// On 2026-09-28 the clock expired as the last round ended. Apple TTS
    /// spoke `wrapUpLine` ("Want to keep playing?") at the same moment Gemini
    /// spoke the game-over farewell. One voice only: Gemini asks to continue
    /// when rounds remain; the farewell chain is the only voice when the
    /// game is over. Local TTS stays quiet on both paths.
    public enum TimeoutSpeech: Equatable {
        case geminiContinue(instructions: String)
        case farewellOnly
    }

    public static func timeoutSpeech(correct: Int, answered: Int, roundsStillAvailable: Bool) -> TimeoutSpeech {
        guard roundsStillAvailable else { return .farewellOnly }
        let line = wrapUpLine(correct: correct, answered: answered)
        return .geminiContinue(
            instructions: "TIME IS UP! Say exactly: \"\(line)\" Then STOP. Do NOT ask another trivia question. Do NOT call get_next_question until the player says yes."
        )
    }
}
