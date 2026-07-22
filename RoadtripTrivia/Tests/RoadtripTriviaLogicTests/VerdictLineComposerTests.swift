import XCTest
@testable import RoadtripTriviaLogic

/// Fixtures for app-owned verdict speech. Encodes the May-14 regressions:
/// "user said D but host said 'correct, the answer is C'" and "host didn't
/// say the correct answer, just said user got it wrong".
final class VerdictLineComposerTests: XCTestCase {

    func test_correctLineContainsPointsAndTotal() {
        let line = VerdictLineComposer.compose(
            isCorrect: true, correctAnswer: "Tokyo",
            pointsPerCorrect: 200, totalPoints: 600
        )
        XCTAssertTrue(line.contains("Correct"))
        XCTAssertTrue(line.contains("200 points"))
        XCTAssertTrue(line.contains("600 points"))
        XCTAssertFalse(line.contains("Tokyo"),
                       "no need to repeat the answer when they got it right")
    }

    func test_incorrectLineAlwaysRevealsCorrectAnswer() {
        let line = VerdictLineComposer.compose(
            isCorrect: false, correctAnswer: "B, Tokyo",
            pointsPerCorrect: 200, totalPoints: 400
        )
        XCTAssertTrue(line.contains("B, Tokyo"),
                      "the correct answer must always be revealed on a miss")
        XCTAssertTrue(line.contains("400 points"))
    }

    func test_revisionUpgradeLine() {
        let line = VerdictLineComposer.composeRevision(
            delta: 1, correctAnswer: "Tokyo", totalPoints: 800
        )
        XCTAssertTrue(line.contains("800 points"))
        XCTAssertTrue(line.lowercased().contains("corrected"))
    }

    func test_revisionDowngradeRevealsAnswer() {
        let line = VerdictLineComposer.composeRevision(
            delta: -1, correctAnswer: "Tokyo", totalPoints: 200
        )
        XCTAssertTrue(line.contains("Tokyo"))
        XCTAssertTrue(line.contains("200 points"))
    }

    func test_challengeOverturnedAnnouncesNewTotal() {
        let line = VerdictLineComposer.composeChallengeOverturned(totalPoints: 1000)
        XCTAssertTrue(line.contains("1000 points"))
    }

    func test_challengeRejectedKeepsAnswerAndTotal() {
        let line = VerdictLineComposer.composeChallengeRejected(
            correctAnswer: "Tokyo", totalPoints: 600
        )
        XCTAssertTrue(line.contains("Tokyo"))
        XCTAssertTrue(line.contains("600 points"))
    }
}
