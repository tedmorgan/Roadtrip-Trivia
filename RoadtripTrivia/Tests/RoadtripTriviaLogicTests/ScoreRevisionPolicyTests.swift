import XCTest
@testable import RoadtripTriviaLogic

final class ScoreRevisionPolicyTests: XCTestCase {

    func test_scoreKey_isStable() {
        XCTAssertEqual(
            ScoreRevisionPolicy.scoreKey(roundNumber: 2, questionIndex: 3),
            "2-3"
        )
    }

    func test_previousCorrectIfRevision_nilWhenHintOrChallenge() {
        XCTAssertNil(
            ScoreRevisionPolicy.previousCorrectIfRevision(existingGraded: true, isHint: true, isChallenge: false)
        )
        XCTAssertNil(
            ScoreRevisionPolicy.previousCorrectIfRevision(existingGraded: true, isHint: false, isChallenge: true)
        )
    }

    func test_previousCorrectIfRevision_returnsStoredWhenPlain() {
        XCTAssertEqual(
            ScoreRevisionPolicy.previousCorrectIfRevision(existingGraded: false, isHint: false, isChallenge: false),
            false
        )
        XCTAssertEqual(
            ScoreRevisionPolicy.previousCorrectIfRevision(existingGraded: true, isHint: false, isChallenge: false),
            true
        )
    }

    func test_correctnessDelta_wrongToRight_plusOne() {
        XCTAssertEqual(
            ScoreRevisionPolicy.correctnessDelta(previous: false, newGraded: true),
            1
        )
    }

    func test_correctnessDelta_rightToWrong_minusOne() {
        XCTAssertEqual(
            ScoreRevisionPolicy.correctnessDelta(previous: true, newGraded: false),
            -1
        )
    }

    func test_correctnessDelta_noChange_zero() {
        XCTAssertEqual(ScoreRevisionPolicy.correctnessDelta(previous: true, newGraded: true), 0)
        XCTAssertEqual(ScoreRevisionPolicy.correctnessDelta(previous: false, newGraded: false), 0)
    }
}
