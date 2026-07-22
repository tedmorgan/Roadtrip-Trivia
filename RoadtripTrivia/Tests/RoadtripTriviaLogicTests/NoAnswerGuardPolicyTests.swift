import XCTest
@testable import RoadtripTriviaLogic

final class NoAnswerGuardPolicyTests: XCTestCase {

    private func decide(
        playerAnswer: String = "B",
        isHint: Bool = false,
        isChallenge: Bool = false,
        isScoringRevision: Bool = false,
        isLightning: Bool = false,
        playerSpokeSinceServe: Bool = true,
        priorDenials: Int = 0
    ) -> NoAnswerGuardPolicy.Verdict {
        NoAnswerGuardPolicy.decide(
            playerAnswer: playerAnswer,
            isHint: isHint,
            isChallenge: isChallenge,
            isScoringRevision: isScoringRevision,
            isLightning: isLightning,
            playerSpokeSinceServe: playerSpokeSinceServe,
            priorDenials: priorDenials
        )
    }

    // MARK: - The 2026-06-12 regression

    /// THE DRIVE-TEST BUG: player paused 2s to think, VAD committed the
    /// silence as a turn, and the model scored `playerAnswer="skip"` —
    /// gong + answer reveal on every pause. No player speech since serve
    /// means the answer is fabricated, even when it looks plausible.
    func test_deniesFabricatedAnswerWhenPlayerNeverSpoke() {
        let verdict = decide(playerAnswer: "skip", playerSpokeSinceServe: false)
        guard case .deny = verdict else {
            return XCTFail("fabricated score for a silent player must be denied, got \(verdict)")
        }
    }

    func test_acceptsRealAnswerWhenPlayerSpoke() {
        XCTAssertEqual(decide(playerAnswer: "skip", playerSpokeSinceServe: true), .accept,
                       "a real spoken 'skip' is a legitimate command")
    }

    // MARK: - Placeholder answers

    /// Placeholders are denied even WITH a transcript — road noise can
    /// produce spurious transcripts, but "no answer" is never a score.
    func test_deniesPlaceholderAnswersRegardlessOfTranscript() {
        for placeholder in ["", "no answer", "(No Answer)", "SILENCE", "n/a",
                            "Time out", "none", "didn't answer"] {
            let verdict = decide(playerAnswer: placeholder, playerSpokeSinceServe: true)
            guard case .deny = verdict else {
                return XCTFail("placeholder \"\(placeholder)\" must be denied, got \(verdict)")
            }
        }
    }

    func test_placeholderDenialIsNotCapped() {
        let verdict = decide(playerAnswer: "no answer",
                             playerSpokeSinceServe: true,
                             priorDenials: 99)
        guard case .deny = verdict else {
            return XCTFail("waiting forever on a silent player is correct — placeholders never expire into acceptance")
        }
    }

    /// "I don't know" is a real (wrong) answer, not a placeholder.
    func test_iDontKnowIsARealAnswer() {
        XCTAssertEqual(decide(playerAnswer: "I don't know"), .accept)
    }

    // MARK: - Fail-open cap (broken transcription stream)

    func test_transcriptDenialCapsOut() {
        let verdict = decide(playerAnswer: "B",
                             playerSpokeSinceServe: false,
                             priorDenials: 2)
        XCTAssertEqual(verdict, .accept,
                       "after maxDenials the guard fails open so a dead transcript stream can't deadlock the game")
    }

    // MARK: - Exemptions

    func test_detoursAndLightningAreExempt() {
        XCTAssertEqual(decide(playerAnswer: "", isHint: true, playerSpokeSinceServe: false), .accept)
        XCTAssertEqual(decide(playerAnswer: "", isChallenge: true, playerSpokeSinceServe: false), .accept)
        XCTAssertEqual(decide(playerAnswer: "", isScoringRevision: true, playerSpokeSinceServe: false), .accept)
        XCTAssertEqual(decide(playerAnswer: "skip", isLightning: true, playerSpokeSinceServe: false), .accept)
    }

    // MARK: - playerProvidedAnswer (answer-window timing)

    /// R2Q5 (2026-07-21): host read the question for ~14s with the mic muted,
    /// the mic opened, and ~1.5s later the model scored. The pre-roll flush at
    /// mic-open transcribed as a phantom answer. Speech within the pre-roll
    /// grace after the window opens must NOT count as a real answer.
    func test_playerProvidedAnswer_ignoresPrerollFlushRightAtWindowOpen() {
        let windowOpen = Date()
        let served = windowOpen.addingTimeInterval(-14) // question served 14s earlier
        // "Speech" 0.3s after the window opened == pre-roll tail, not an answer.
        let prerollNoise = windowOpen.addingTimeInterval(0.3)
        XCTAssertFalse(NoAnswerGuardPolicy.playerProvidedAnswer(
            lastPlayerSpeechAt: prerollNoise,
            answerWindowOpenedAt: windowOpen,
            questionServedAt: served
        ))
    }

    func test_playerProvidedAnswer_countsRealAnswerAfterGrace() {
        let windowOpen = Date()
        let realAnswer = windowOpen.addingTimeInterval(2.0) // spoke 2s after mic live
        XCTAssertTrue(NoAnswerGuardPolicy.playerProvidedAnswer(
            lastPlayerSpeechAt: realAnswer,
            answerWindowOpenedAt: windowOpen,
            questionServedAt: windowOpen.addingTimeInterval(-10)
        ))
    }

    func test_playerProvidedAnswer_noAnswerWhenWindowNeverOpened() {
        // Host still reading (window not open) but a question was served —
        // no legitimate answer is possible yet.
        XCTAssertFalse(NoAnswerGuardPolicy.playerProvidedAnswer(
            lastPlayerSpeechAt: Date(),
            answerWindowOpenedAt: nil,
            questionServedAt: Date().addingTimeInterval(-2)
        ))
    }

    func test_playerProvidedAnswer_noSpeechAtAll() {
        XCTAssertFalse(NoAnswerGuardPolicy.playerProvidedAnswer(
            lastPlayerSpeechAt: nil,
            answerWindowOpenedAt: Date(),
            questionServedAt: Date().addingTimeInterval(-5)
        ))
    }

    func test_playerProvidedAnswer_failsOpenWhenNoTimingTracked() {
        // No serve and no window tracked — degrade to old fail-open behavior
        // so a telemetry gap can't deadlock the game.
        XCTAssertTrue(NoAnswerGuardPolicy.playerProvidedAnswer(
            lastPlayerSpeechAt: nil,
            answerWindowOpenedAt: nil,
            questionServedAt: nil
        ))
    }

    // MARK: - Normalization

    func test_normalizeStripsPunctuationAndCase() {
        XCTAssertEqual(NoAnswerGuardPolicy.normalize("(No Answer)"), "no answer")
        XCTAssertEqual(NoAnswerGuardPolicy.normalize("  N/A "), "n a")
        XCTAssertEqual(NoAnswerGuardPolicy.normalize("didn't answer"), "didn t answer")
        XCTAssertEqual(NoAnswerGuardPolicy.normalize("West Egg"), "west egg")
    }
}
