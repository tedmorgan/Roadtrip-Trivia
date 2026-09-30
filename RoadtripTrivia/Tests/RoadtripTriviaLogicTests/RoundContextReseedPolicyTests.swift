import XCTest
@testable import RoadtripTriviaLogic

final class RoundContextReseedPolicyTests: XCTestCase {

    func test_doesNotReseedRound1() {
        XCTAssertFalse(
            RoundContextReseedPolicy.shouldReseed(
                nextRoundNumber: 1,
                nextQuestionIndex: 1,
                lastReseededRound: nil
            )
        )
    }

    func test_reseedsFirstQuestionOfLaterRounds() {
        XCTAssertTrue(
            RoundContextReseedPolicy.shouldReseed(
                nextRoundNumber: 2,
                nextQuestionIndex: 1,
                lastReseededRound: nil
            )
        )
        XCTAssertTrue(
            RoundContextReseedPolicy.shouldReseed(
                nextRoundNumber: 5,
                nextQuestionIndex: 1,
                lastReseededRound: 2
            )
        )
    }

    func test_doesNotReseedMidRound() {
        XCTAssertFalse(
            RoundContextReseedPolicy.shouldReseed(
                nextRoundNumber: 2,
                nextQuestionIndex: 3,
                lastReseededRound: nil
            )
        )
    }

    func test_doesNotReseedTheSameRoundTwice() {
        XCTAssertFalse(
            RoundContextReseedPolicy.shouldReseed(
                nextRoundNumber: 2,
                nextQuestionIndex: 1,
                lastReseededRound: 2
            )
        )
    }

    func test_fillerWaitsUntilTheReseedIsActuallySlow() {
        XCTAssertFalse(
            RoundContextReseedPolicy.shouldSpeakRoundBoundaryFiller(
                secondsSincePlaybackDrained: 1.2,
                hostHasSpokenSinceReseed: false
            )
        )
        XCTAssertFalse(
            RoundContextReseedPolicy.shouldSpeakRoundBoundaryFiller(
                secondsSincePlaybackDrained: 6,
                hostHasSpokenSinceReseed: true
            )
        )
        XCTAssertTrue(
            RoundContextReseedPolicy.shouldSpeakRoundBoundaryFiller(
                secondsSincePlaybackDrained: 4,
                hostHasSpokenSinceReseed: false
            )
        )
    }

    func test_bridgeInstructionForbidsSpeech() {
        let text = RoundContextReseedPolicy.bridgeInstruction(
            announce: "Round 2 — the category is History!"
        )
        XCTAssertTrue(text.contains("Do not speak"))
        XCTAssertTrue(text.contains("Do not read a question"))
        XCTAssertTrue(text.contains("History"))
        XCTAssertFalse(text.contains("Say this EXACT line"))
    }

    func test_doesNotOmitAnnounceAfterReseed() {
        XCTAssertFalse(
            RoundContextReseedPolicy.shouldOmitAnnounce(
                roundNumber: 2,
                questionIndex: 1,
                lastReseededRound: 2
            )
        )
        XCTAssertFalse(
            RoundContextReseedPolicy.shouldOmitAnnounce(
                roundNumber: 2,
                questionIndex: 1,
                lastReseededRound: nil
            )
        )
    }

    func test_postReseedInstructionsSkipSetup() {
        let text = RoundContextReseedPolicy.postReseedInstructions(
            roundNumber: 3,
            category: "Science & Nature"
        )
        XCTAssertTrue(text.contains("get_next_question"))
        XCTAssertTrue(text.contains("Do NOT greet"))
        XCTAssertTrue(text.contains("Science & Nature"))
        XCTAssertTrue(text.contains("announce"))
        XCTAssertFalse(text.contains("already announced"))
    }

    func test_pastRoundsSummaryIsCompact() {
        XCTAssertEqual(RoundContextReseedPolicy.pastRoundsSummary(rounds: []), "None yet.")
        XCTAssertEqual(
            RoundContextReseedPolicy.pastRoundsSummary(rounds: [
                (1, "Geography", 3, 5),
                (2, "History", 2, 5),
            ]),
            "R1 Geography 3/5; R2 History 2/5"
        )
    }

    func test_lightningWrapUpFragmentDoesNotStartANewRound() {
        XCTAssertFalse(
            LightningAnnouncementPolicy.isNewLightningStart(
                transcript: "Lightning Round",
                lightningTimedOut: true
            )
        )
        XCTAssertFalse(
            LightningAnnouncementPolicy.isNewLightningStart(
                transcript: "Time is up. Lightning round over.",
                lightningTimedOut: false
            )
        )
    }

    func test_lightningStartStillDetectedBeforeTimeout() {
        XCTAssertTrue(
            LightningAnnouncementPolicy.isNewLightningStart(
                transcript: "Time for a lightning round!",
                lightningTimedOut: false
            )
        )
    }

    func test_wrapUpLineStatesTheScore() {
        let line = LightningAnnouncementPolicy.wrapUpLine(correct: 4, answered: 5)
        XCTAssertTrue(line.localizedCaseInsensitiveContains("time is up"))
        XCTAssertTrue(line.contains("4"))
        XCTAssertTrue(line.contains("5"))
    }

    func test_lightningTimeoutUsesOneHost() {
        let ending = LightningAnnouncementPolicy.timeoutSpeech(
            correct: 3, answered: 5, roundsStillAvailable: false
        )
        XCTAssertEqual(ending, .farewellOnly)

        let continuing = LightningAnnouncementPolicy.timeoutSpeech(
            correct: 3, answered: 5, roundsStillAvailable: true
        )
        guard case .geminiContinue(let instructions) = continuing else {
            return XCTFail("rounds remaining should be a single Gemini line")
        }
        XCTAssertTrue(instructions.contains("3"))
        XCTAssertTrue(instructions.contains("5"))
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("want to keep playing"))
    }
}
