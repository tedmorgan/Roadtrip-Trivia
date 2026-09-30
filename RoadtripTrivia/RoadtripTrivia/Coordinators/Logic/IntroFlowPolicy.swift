import Foundation

/// App-owned intro / first-question copy and timing.
///
/// These strings used to live only in `SystemPromptBuilder` and
/// `RealtimeGameCoordinator`, which `make test` does not compile. Build 30–31
/// then shipped: no welcome, skipped ages, and a duplicated
/// "let me pull up your first question" that preceded a crash.
enum IntroFlowPolicy {

    static let welcomeLine = "Welcome to Roadtrip Trivia!"

    /// First Grok turn — same Sal voice as the rest of the intro. Do not use
    /// `force_message` here; that is a separate TTS path and sounds like a
    /// different host.
    static let firstTurnInstructions = """
        Say exactly "\(welcomeLine)" with big game-show energy, then ask ONLY \
        for their team name. STOP and wait. Do not ask ages or difficulty yet.
        """

    static let newGameSetupBlock = """
        NEW GAME SETUP — ask ONE question per turn, WAIT for the answer, then ask the next:
        Open with "\(welcomeLine)" then ask ONLY for their team name — STOP and wait.
        Next: Ask ONLY about ages, exactly once: "Are the players kids, teens, adults, or a mix?" — STOP and wait. \
        Do not ask ages again. Any reply is the ages answer, even if it is short. Do NOT skip to difficulty.
        Next: Ask ONLY which difficulty: "Pick your difficulty: Simple, Tricky, Wicked Hard, or Einstein. Which one?" — STOP and wait.
        After all 3 answers, do NOT speak — call set_game_config exactly once (playerCount=1) NOW.
        """

    /// Keep-alive while the first batch is generating. One short host line
    /// covers most of the server latency without mentioning loading or using
    /// the duplicated "let me pull up…" wording that crashed build 31.
    static let batchPendingInstruction = """
        Say exactly: "Great choice! Road warriors, get ready—Round One is about \
        to hit the road!" Then STOP and wait silently. Do NOT mention loading or \
        pulling up a question. Do NOT call get_next_question again on your own.
        """

    static let round1NudgeInstructions = """
        Questions are ready. Call get_next_question NOW. Do not speak first — \
        no "let me pull up", no "hang tight", no filler. Tool call only.
        """

    static let doNotAnnounceLoading = "Do not say you are loading or pulling up questions."

    /// After three host setup turns, wait this long for a difficulty answer
    /// before forcing `set_game_config`.
    static let postThirdHostTurnTimeout: TimeInterval = 20

    /// After the player finishes speaking *following* the third host turn.
    static let postDifficultyAnswerDelay: TimeInterval = 4

    /// Fallback timeout after the third host question. Nil if setup is incomplete.
    static func timeoutAfterHostTurn(hostTurnsCompleted: Int) -> TimeInterval? {
        hostTurnsCompleted >= 3 ? postThirdHostTurnTimeout : nil
    }

    /// Fire only after the third host question AND a later player utterance.
    /// Early VAD stops (team name / ages / cabin noise) must not skip ages.
    static func delayAfterPlayerStop(
        hostTurnsCompleted: Int,
        playerStopsAfterThirdHostTurn: Int
    ) -> TimeInterval? {
        guard hostTurnsCompleted >= 3, playerStopsAfterThirdHostTurn >= 1 else {
            return nil
        }
        return postDifficultyAnswerDelay
    }
}
