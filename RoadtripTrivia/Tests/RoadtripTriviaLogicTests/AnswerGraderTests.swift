import XCTest
@testable import RoadtripTriviaLogic

final class AnswerGraderTests: XCTestCase {

    // MARK: - normalizedToken

    func test_normalizedToken_lowercasesAndStripsPunctuation() {
        XCTAssertEqual(AnswerGrader.normalizedToken("  Rugby!  "), "rugby")
        XCTAssertEqual(AnswerGrader.normalizedToken("C: Rugby"), "c rugby")
        XCTAssertEqual(AnswerGrader.normalizedToken("HELLO, WORLD"), "hello world")
        XCTAssertEqual(AnswerGrader.normalizedToken(""), "")
    }

    // MARK: - answerLetter

    func test_answerLetter_recognizesSpokenSingleLetters() {
        XCTAssertEqual(AnswerGrader.answerLetter(from: "a"), "a")
        XCTAssertEqual(AnswerGrader.answerLetter(from: "be"), "b")
        XCTAssertEqual(AnswerGrader.answerLetter(from: "see"), "c")
        XCTAssertEqual(AnswerGrader.answerLetter(from: "dee"), "d")
    }

    func test_answerLetter_recognizesShortPhrasesContainingTheLetter() {
        XCTAssertEqual(AnswerGrader.answerLetter(from: "the answer is bee"), "b")
        XCTAssertEqual(AnswerGrader.answerLetter(from: "answer c"), "c")
    }

    func test_answerLetter_rejectsLongPhrasesToAvoidFalsePositives() {
        // 5+ words: don't extract — it's clearly free-response prose.
        XCTAssertNil(AnswerGrader.answerLetter(from: "i think the answer is rugby"))
    }

    func test_answerLetter_rejectsUnrelatedShortPhrases() {
        XCTAssertNil(AnswerGrader.answerLetter(from: "rugby"))
        XCTAssertNil(AnswerGrader.answerLetter(from: "tennis ball"))
    }

    // MARK: - spokenCorrectAnswer (letter -> full text)

    func test_spokenCorrectAnswer_resolvesBareLetterToOptionText() {
        let options = ["A: Berlin", "B: Oslo", "C: Madrid", "D: Rome"]
        XCTAssertEqual(AnswerGrader.spokenCorrectAnswer(correctAnswer: "B", options: options), "Oslo")
        XCTAssertEqual(AnswerGrader.spokenCorrectAnswer(correctAnswer: "d", options: options), "Rome")
    }

    func test_spokenCorrectAnswer_stripsLabelFromLabeledAnswer() {
        XCTAssertEqual(AnswerGrader.spokenCorrectAnswer(correctAnswer: "B: Oslo", options: nil), "Oslo")
        XCTAssertEqual(AnswerGrader.spokenCorrectAnswer(correctAnswer: "C) Rugby", options: nil), "Rugby")
    }

    func test_spokenCorrectAnswer_passesThroughFreeResponse() {
        XCTAssertEqual(AnswerGrader.spokenCorrectAnswer(correctAnswer: "Oslo", options: nil), "Oslo")
        XCTAssertEqual(AnswerGrader.spokenCorrectAnswer(correctAnswer: "The Pacific Ocean", options: nil), "The Pacific Ocean")
    }

    func test_spokenCorrectAnswer_handlesMissingOrEmpty() {
        XCTAssertEqual(AnswerGrader.spokenCorrectAnswer(correctAnswer: nil, options: nil), "unknown")
        XCTAssertEqual(AnswerGrader.spokenCorrectAnswer(correctAnswer: "   ", options: nil), "unknown")
    }

    func test_spokenCorrectAnswer_bareLetterWithoutMatchingOptionFallsBack() {
        // No options to resolve against — return the letter rather than crash.
        XCTAssertEqual(AnswerGrader.spokenCorrectAnswer(correctAnswer: "B", options: nil), "B")
        // Options present but none match the letter — return the letter.
        XCTAssertEqual(AnswerGrader.spokenCorrectAnswer(correctAnswer: "E", options: ["A: One", "B: Two"]), "E")
    }

    // MARK: - isCorrect — direct text match

    func test_isCorrect_textMatchesIgnoringCaseAndPunctuation() {
        XCTAssertTrue(grade(player: "Rugby", correct: "C: Rugby"))
        XCTAssertTrue(grade(player: "rugby", correct: "rugby"))
        XCTAssertTrue(grade(player: "  rugby! ", correct: "Rugby"))
    }

    // MARK: - isCorrect — letter answers

    func test_isCorrect_playerSaysLetter_correctIsLetter() {
        XCTAssertTrue(grade(player: "B", correct: "B"))
        XCTAssertTrue(grade(player: "bee", correct: "B"))
        XCTAssertTrue(grade(player: "the answer is bee", correct: "B"))
    }

    func test_isCorrect_playerSaysLetter_correctIsLabeledOption() {
        // R3Q4 regression — "C" should match "C: Rugby".
        XCTAssertTrue(grade(
            player: "C",
            correct: "C: Rugby",
            options: ["A: Soccer", "B: Tennis", "C: Rugby", "D: Cricket"]
        ))
        XCTAssertTrue(grade(
            player: "see",
            correct: "C: Rugby",
            options: ["A: Soccer", "B: Tennis", "C: Rugby", "D: Cricket"]
        ))
    }

    func test_isCorrect_playerSaysOptionText_correctIsLetter() {
        XCTAssertTrue(grade(
            player: "Rugby",
            correct: "C",
            options: ["A: Soccer", "B: Tennis", "C: Rugby", "D: Cricket"]
        ))
    }

    // MARK: - isCorrect — wrong answers

    func test_isCorrect_returnsFalseOnWrongLetter() {
        XCTAssertFalse(grade(
            player: "D",
            correct: "C: Rugby",
            options: ["A: Soccer", "B: Tennis", "C: Rugby", "D: Cricket"]
        ))
    }

    func test_isCorrect_returnsFalseOnWrongOptionText() {
        XCTAssertFalse(grade(
            player: "Cricket",
            correct: "C: Rugby",
            options: ["A: Soccer", "B: Tennis", "C: Rugby", "D: Cricket"]
        ))
    }

    func test_isCorrect_doesNotFalsePositiveOnShortUnrelatedTokens() {
        // "kayaking" must not match "C: Triathlon" via free-response contains.
        XCTAssertFalse(grade(
            player: "kayaking",
            correct: "C: Triathlon",
            options: ["A: Decathlon", "B: Pentathlon", "C: Triathlon", "D: Heptathlon"]
        ))
    }

    // MARK: - isCorrect — free-response tolerance

    func test_isCorrect_tolerantOfSpeechArtifactsOnFreeResponse() {
        // "the lion king" said quickly might transcribe as "lion king".
        XCTAssertTrue(grade(player: "lion king", correct: "The Lion King"))
        XCTAssertTrue(grade(player: "the lion king movie", correct: "The Lion King"))
    }

    func test_isCorrect_tolerance_doesNotApplyToShortStrings() {
        // 3-char "ace" must not be tolerantly matched against "race".
        XCTAssertFalse(grade(player: "ace", correct: "ra"))
    }

    // MARK: - isCorrect — stale-question guard

    func test_isCorrect_fallsBackToAIWhenQuestionIndexMismatched() {
        // Player report references question 2 but we're already on question 3.
        // We must NOT grade with question 3's answer key.
        XCTAssertTrue(AnswerGrader.isCorrect(
            playerAnswer: "Rugby",
            correctAnswer: "C: Tennis",          // current question's answer
            options: nil,
            playerQuestionIndex: 2,              // stale!
            currentQuestionIndex: 3,
            playerRoundNumber: 1,
            currentRoundNumber: 1,
            fallbackIsCorrect: true              // AI judged correct
        ), "stale question must defer to AI's isCorrect")
    }

    func test_isCorrect_fallsBackToAIWhenRoundMismatched() {
        XCTAssertFalse(AnswerGrader.isCorrect(
            playerAnswer: "Rugby",
            correctAnswer: "C: Rugby",
            options: nil,
            playerQuestionIndex: 1,
            currentQuestionIndex: 1,
            playerRoundNumber: 2,                // stale round
            currentRoundNumber: 3,
            fallbackIsCorrect: false
        ))
    }

    func test_isCorrect_acceptsNilRoundFromAI() {
        // AI sometimes omits roundNumber; that should not trigger the guard.
        XCTAssertTrue(AnswerGrader.isCorrect(
            playerAnswer: "Rugby",
            correctAnswer: "C: Rugby",
            options: nil,
            playerQuestionIndex: 1,
            currentQuestionIndex: 1,
            playerRoundNumber: nil,
            currentRoundNumber: 1,
            fallbackIsCorrect: false
        ))
    }

    // MARK: - isCorrect — missing data

    func test_isCorrect_fallsBackToAIWhenAnswerKeyMissing() {
        XCTAssertTrue(AnswerGrader.isCorrect(
            playerAnswer: "Rugby",
            correctAnswer: nil,
            options: nil,
            playerQuestionIndex: 1,
            currentQuestionIndex: 1,
            playerRoundNumber: 1,
            currentRoundNumber: 1,
            fallbackIsCorrect: true
        ))
    }

    func test_isCorrect_fallsBackToAIWhenPlayerAnswerMissing() {
        XCTAssertFalse(AnswerGrader.isCorrect(
            playerAnswer: "  ",
            correctAnswer: "Rugby",
            options: nil,
            playerQuestionIndex: 1,
            currentQuestionIndex: 1,
            playerRoundNumber: 1,
            currentRoundNumber: 1,
            fallbackIsCorrect: false
        ))
    }

    // MARK: - Helper

    /// Invokes `AnswerGrader.isCorrect` with sane defaults so the
    /// individual tests stay focused on the field they're varying.
    private func grade(
        player: String,
        correct: String,
        options: [String]? = nil,
        questionIndex: Int = 1,
        roundNumber: Int = 1
    ) -> Bool {
        AnswerGrader.isCorrect(
            playerAnswer: player,
            correctAnswer: correct,
            options: options,
            playerQuestionIndex: questionIndex,
            currentQuestionIndex: questionIndex,
            playerRoundNumber: roundNumber,
            currentRoundNumber: roundNumber,
            fallbackIsCorrect: false
        )
    }
}
