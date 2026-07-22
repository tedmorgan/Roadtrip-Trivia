import XCTest
@testable import RoadtripTriviaLogic

final class ReportScoreResultContractTests: XCTestCase {

    // MARK: - Typed struct → dictionary (compiler-enforced contract)

    /// THE KEY TEST. `ReportScoreResult` is a typed struct whose
    /// `init` has a non-optional parameter for every field the AI
    /// needs. If someone removes `correctAnswer` from the struct,
    /// the coordinator's call site won't compile. This test verifies
    /// that `toDictionary()` produces a dictionary that passes the
    /// contract validation — closing the loop between the struct and
    /// the required-keys contract.
    func test_toDictionary_passesContractValidation() {
        let result = makeTypedResult()
        let dict = result.toDictionary()
        XCTAssertTrue(
            ReportScoreResultContract.isValid(dict),
            "toDictionary() must produce all required keys. Missing: \(ReportScoreResultContract.missingKeys(in: dict))"
        )
    }

    /// Verify each required key is present in the dictionary output.
    func test_toDictionary_containsEveryRequiredKey() {
        let dict = makeTypedResult().toDictionary()
        for key in ReportScoreResultContract.requiredKeys {
            XCTAssertNotNil(dict[key], "Required key '\(key)' missing from toDictionary() output")
        }
    }

    // MARK: - correctAnswer field (5.log regression)

    /// THE 5.log REGRESSION (2026-05-07). The AI failed to announce
    /// the correct answer on R1Q1, R3Q1, R4Q3 because
    /// `correctAnswer` was never in the tool result.
    func test_correctAnswerIsRequired() {
        XCTAssertTrue(
            ReportScoreResultContract.requiredKeys.contains("correctAnswer"),
            "correctAnswer MUST be a required key — without it the AI cannot announce the answer on wrong questions"
        )
    }

    /// Verify `correctAnswer` value is passed through correctly.
    func test_toDictionary_correctAnswerValuePreserved() {
        let result = ReportScoreResult(
            isCorrect: false,
            correctAnswer: "B: Tokyo",
            totalPoints: 0,
            roundsRemaining: 3, nextAction: "Continue."
        )
        let dict = result.toDictionary()
        XCTAssertEqual(dict["correctAnswer"] as? String, "B: Tokyo")
    }

    // MARK: - roundsRemaining field (3.log regression)

    /// `roundsRemaining` prevents the AI from hallucinating round
    /// counts (3.log regression). Must remain required.
    func test_roundsRemainingIsRequired() {
        XCTAssertTrue(
            ReportScoreResultContract.requiredKeys.contains("roundsRemaining"),
            "roundsRemaining MUST be required — without it the AI hallucinates round counts"
        )
    }

    /// Verify `roundsRemaining` value is passed through correctly.
    func test_toDictionary_roundsRemainingValuePreserved() {
        let result = ReportScoreResult(
            isCorrect: true, correctAnswer: "A",
            totalPoints: 200,
            roundsRemaining: 5, nextAction: "Continue."
        )
        let dict = result.toDictionary()
        XCTAssertEqual(dict["roundsRemaining"] as? Int, 5)
    }

    // MARK: - Missing key detection

    func test_missingCorrectAnswerFailsValidation() {
        var dict = makeTypedResult().toDictionary()
        dict.removeValue(forKey: "correctAnswer")
        XCTAssertFalse(ReportScoreResultContract.isValid(dict))
        XCTAssertTrue(ReportScoreResultContract.missingKeys(in: dict).contains("correctAnswer"))
    }

    func test_missingIsCorrectFailsValidation() {
        var dict = makeTypedResult().toDictionary()
        dict.removeValue(forKey: "isCorrect")
        XCTAssertFalse(ReportScoreResultContract.isValid(dict))
    }

    func test_missingNextActionFailsValidation() {
        var dict = makeTypedResult().toDictionary()
        dict.removeValue(forKey: "nextAction")
        XCTAssertFalse(ReportScoreResultContract.isValid(dict))
    }

    func test_emptyResultReportsAllKeysMissing() {
        let missing = ReportScoreResultContract.missingKeys(in: [:])
        XCTAssertEqual(missing, ReportScoreResultContract.requiredKeys)
    }

    // MARK: - Extra keys are allowed

    func test_extraKeysDoNotBreakValidation() {
        var dict = makeTypedResult().toDictionary()
        dict["hintDenied"] = true
        dict["challengeOverturned"] = true
        dict["scoreUpdated"] = true
        XCTAssertTrue(ReportScoreResultContract.isValid(dict))
    }

    // MARK: - Helpers

    private func makeTypedResult() -> ReportScoreResult {
        ReportScoreResult(
            isCorrect: true,
            correctAnswer: "A: Paris",
            totalPoints: 800,
            roundsRemaining: 3,
            nextAction: "Continue."
        )
    }
}
