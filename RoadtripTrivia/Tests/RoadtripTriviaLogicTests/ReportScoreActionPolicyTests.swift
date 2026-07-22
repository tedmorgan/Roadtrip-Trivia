import XCTest
@testable import RoadtripTriviaLogic

final class ReportScoreActionPolicyTests: XCTestCase {

    // MARK: - decide(): regime detection

    func test_midRound_q1ThroughQ4_returnsMidRound() {
        for qIdx in [1, 2, 3, 4] {
            let outcome = ReportScoreActionPolicy.decide(
                questionIndex: qIdx,
                isLightningRound: false,
                canPlayRound: true,
                roundsLeftAfterScoring: 5
            )
            XCTAssertEqual(outcome, .midRound, "Q\(qIdx) of standard round should be midRound")
        }
    }

    /// Lightning rounds end on a timer, not on a 5-question boundary —
    /// `decide` must never report a lightning question as "round
    /// complete", regardless of question index.
    func test_lightningRound_neverRoundComplete() {
        for qIdx in [1, 5, 10, 25] {
            let outcome = ReportScoreActionPolicy.decide(
                questionIndex: qIdx,
                isLightningRound: true,
                canPlayRound: true,
                roundsLeftAfterScoring: 2
            )
            XCTAssertEqual(outcome, .midRound, "lightning Q\(qIdx) must always be midRound")
        }
    }

    func test_q5OfStandardRound_withRoundsLeft_returnsContinue() {
        let outcome = ReportScoreActionPolicy.decide(
            questionIndex: 5,
            isLightningRound: false,
            canPlayRound: true,
            roundsLeftAfterScoring: 3
        )
        XCTAssertEqual(outcome, .roundCompleteContinue(roundsLeft: 3))
    }

    func test_q5OfStandardRound_canPlayFalse_returnsNoRoundsLeft() {
        let outcome = ReportScoreActionPolicy.decide(
            questionIndex: 5,
            isLightningRound: false,
            canPlayRound: false,
            roundsLeftAfterScoring: 0
        )
        XCTAssertEqual(outcome, .roundCompleteNoRoundsLeft)
    }

    func test_questionIndexAbove5_treatedAsRoundComplete() {
        // Defensive: if Gemini ever sends questionIndex > 5 we still
        // want to recognize the round is over.
        let outcome = ReportScoreActionPolicy.decide(
            questionIndex: 6,
            isLightningRound: false,
            canPlayRound: true,
            roundsLeftAfterScoring: 1
        )
        XCTAssertEqual(outcome, .roundCompleteContinue(roundsLeft: 1))
    }

    func test_negativeRoundsLeftClampsToZero() {
        // RoundTracker shouldn't ever return negative, but defensively
        // the policy clamps so the output never includes "−1 rounds".
        let outcome = ReportScoreActionPolicy.decide(
            questionIndex: 5,
            isLightningRound: false,
            canPlayRound: true,
            roundsLeftAfterScoring: -3
        )
        XCTAssertEqual(outcome, .roundCompleteContinue(roundsLeft: 0))
    }

    // MARK: - nextActionText(): hard-coded regression guards

    func test_midRoundText_demandsImmediateGetNextQuestion() {
        let text = ReportScoreActionPolicy.nextActionText(for: .midRound)
        XCTAssertTrue(text.contains("get_next_question"), "text: \(text)")
        XCTAssertTrue(text.contains("IMMEDIATELY"), "text: \(text)")
    }

    /// THE PRIMARY 4.log REGRESSION (R2 end with 1 round left, AI said
    /// "no more rounds"). The text must (a) state the count, (b) ask
    /// to continue, (c) explicitly forbid the offending wording.
    func test_continueText_oneRoundLeft_usesSingularAndForbidsOver() {
        let outcome = ReportScoreOutcome.roundCompleteContinue(roundsLeft: 1)
        let text = ReportScoreActionPolicy.nextActionText(for: outcome)
        XCTAssertTrue(text.contains("1 more round"),
                      "must use singular '1 more round': \(text)")
        XCTAssertFalse(text.contains("1 more rounds"),
                       "must NOT pluralize for 1: \(text)")
        XCTAssertTrue(text.lowercased().contains("ask if they want to continue"),
                      "must ask to continue: \(text)")
        XCTAssertTrue(text.contains("Do NOT"),
                      "must include forbidding clause: \(text)")
        XCTAssertTrue(text.lowercased().contains("exhausted"),
                      "must mention 'exhausted' as forbidden wording: \(text)")
        XCTAssertTrue(text.lowercased().contains("no more rounds"),
                      "must mention 'no more rounds' as forbidden wording: \(text)")
        XCTAssertTrue(text.lowercased().contains("last round"),
                      "must mention 'last round' as forbidden wording: \(text)")
    }

    /// THE SECONDARY 4.log REGRESSION: after a mid-session purchase,
    /// R3 ended with 3 rounds left and the AI again hallucinated "no
    /// more rounds". Verify the post-purchase 3-rounds-left wording.
    func test_continueText_postPurchase_threeRoundsLeft_pluralForm() {
        let outcome = ReportScoreOutcome.roundCompleteContinue(roundsLeft: 3)
        let text = ReportScoreActionPolicy.nextActionText(for: outcome)
        XCTAssertTrue(text.contains("3 more rounds"),
                      "must use plural '3 more rounds': \(text)")
        XCTAssertFalse(text.contains("3 more round "),
                       "must not use singular for 3: \(text)")
        XCTAssertTrue(text.lowercased().contains("brief round summary"),
                      "must request a brief summary: \(text)")
    }

    func test_continueText_zeroRoundsLeft_stillForbidsLastRoundWording() {
        // Edge: canPlayRound was true but roundsLeftAfterScoring=0.
        // The text still goes through the `roundCompleteContinue`
        // branch; we don't want it accidentally saying "last round" in
        // that path — only the `roundCompleteNoRoundsLeft` regime
        // should.
        let outcome = ReportScoreOutcome.roundCompleteContinue(roundsLeft: 0)
        let text = ReportScoreActionPolicy.nextActionText(for: outcome)
        XCTAssertTrue(text.contains("0 more rounds"))
        XCTAssertTrue(text.contains("Do NOT"),
                      "the forbidding clause should still be present: \(text)")
    }

    func test_noRoundsLeftText_drivesAppOwnedFarewell() {
        let text = ReportScoreActionPolicy.nextActionText(for: .roundCompleteNoRoundsLeft)
        XCTAssertTrue(text.contains("LAST available round"))
        XCTAssertTrue(text.contains("Do NOT call end_game"),
                      "AI must not call end_game during no-rounds farewell: \(text)")
        XCTAssertTrue(text.contains("Do NOT call get_next_question"),
                      "AI must not start another question: \(text)")
        XCTAssertTrue(text.contains("Do NOT ask if they want to play again"),
                      "AI must not solicit a new game: \(text)")
    }

    // MARK: - End-to-end log replay

    /// Replays the relevant slice of `debug-f3b222 3.log` (2026-05-04)
    /// scoring sequence: R1 ends with 2 left, R2 ends with 1 left,
    /// then user purchases 3, R3 ends with 3 left. Each completion
    /// must yield `roundCompleteContinue` with the correct count —
    /// none should be `roundCompleteNoRoundsLeft`.
    func test_log4ScoringSequence_neverFalseEndsTheGame() {
        struct Step {
            let label: String
            let qIdx: Int
            let isLightning: Bool
            let canPlay: Bool
            let roundsLeft: Int
            let expected: ReportScoreOutcome
        }
        let steps: [Step] = [
            // R1: 5 questions, then complete with 2 rounds left.
            Step(label: "R1Q1", qIdx: 1, isLightning: false, canPlay: true,  roundsLeft: 3, expected: .midRound),
            Step(label: "R1Q5", qIdx: 5, isLightning: false, canPlay: true,  roundsLeft: 2, expected: .roundCompleteContinue(roundsLeft: 2)),
            // R2: complete with 1 round left.
            Step(label: "R2Q5", qIdx: 5, isLightning: false, canPlay: true,  roundsLeft: 1, expected: .roundCompleteContinue(roundsLeft: 1)),
            // (User purchases 3 mid-session — RoundTracker now reports
            // canPlay=true, totalRoundsAvailable=4 going into R3. R3
            // consumes one → rounds_left = 3 after scoring R3Q5.)
            Step(label: "R3Q5_postPurchase", qIdx: 5, isLightning: false, canPlay: true, roundsLeft: 3, expected: .roundCompleteContinue(roundsLeft: 3)),
        ]
        for step in steps {
            let outcome = ReportScoreActionPolicy.decide(
                questionIndex: step.qIdx,
                isLightningRound: step.isLightning,
                canPlayRound: step.canPlay,
                roundsLeftAfterScoring: step.roundsLeft
            )
            XCTAssertEqual(outcome, step.expected, "step \(step.label): expected \(step.expected) got \(outcome)")
            // And the text must NOT claim rounds are exhausted.
            let text = ReportScoreActionPolicy.nextActionText(for: outcome)
            switch outcome {
            case .roundCompleteContinue:
                XCTAssertFalse(text.lowercased().contains("last available round"),
                               "step \(step.label) must not say 'last available round': \(text)")
            default: break
            }
        }
    }

    /// Equality lock-in: outcomes with different counts are distinct
    /// (otherwise the post-purchase regression test wouldn't be able
    /// to differentiate "1 round left" from "3 rounds left").
    func test_outcomeEquality_distinguishesByCount() {
        XCTAssertNotEqual(
            ReportScoreOutcome.roundCompleteContinue(roundsLeft: 1),
            ReportScoreOutcome.roundCompleteContinue(roundsLeft: 3)
        )
        XCTAssertEqual(
            ReportScoreOutcome.roundCompleteContinue(roundsLeft: 1),
            ReportScoreOutcome.roundCompleteContinue(roundsLeft: 1)
        )
    }
}
