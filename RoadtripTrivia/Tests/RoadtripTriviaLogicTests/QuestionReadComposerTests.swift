import XCTest
@testable import RoadtripTriviaLogic

final class QuestionReadComposerTests: XCTestCase {

    func test_readLineNumbersAPlainQuestionOnce() {
        let line = QuestionReadComposer.readLine(
            questionIndex: 1,
            questionText: "Which cape is the oldest on Cape Cod?"
        )
        XCTAssertEqual(line, "Question 1. Which cape is the oldest on Cape Cod?")
        XCTAssertEqual(line.components(separatedBy: "Question 1").count - 1, 1)
    }

    func test_stripsANumberTheGeneratorAlreadyAdded() {
        let line = QuestionReadComposer.readLine(
            questionIndex: 2,
            questionText: "Question 2: Which isthmus is the narrowest?"
        )
        XCTAssertEqual(line, "Question 2. Which isthmus is the narrowest?")
        XCTAssertFalse(line.contains("Question 2:"))
        XCTAssertEqual(line.components(separatedBy: "Question 2").count - 1, 1)
    }

    func test_stripsAMismatchedLeadingNumber() {
        // The generator labeled every item "Question 1" while the app
        // served question 4. The spoken line uses the app's index once.
        let line = QuestionReadComposer.readLine(
            questionIndex: 4,
            questionText: "Question 1. What defines the tree line?"
        )
        XCTAssertEqual(line, "Question 4. What defines the tree line?")
        XCTAssertFalse(line.contains("Question 1"))
    }

    func test_bodyKeepsTheQuestionWhenStrippingWouldEraseIt() {
        XCTAssertEqual(QuestionReadComposer.body(from: "Question 3"), "Question 3")
    }

    func test_instructionTellsTheHostToReadTheComposedLineOnce() {
        let withAnnounce = QuestionReadComposer.toolInstruction(hasAnnounce: true)
        XCTAssertTrue(withAnnounce.contains("announce field VERBATIM"))
        XCTAssertTrue(withAnnounce.contains("read field VERBATIM exactly once"))
        XCTAssertTrue(withAnnounce.contains("do not also read questionText"))

        let without = QuestionReadComposer.toolInstruction(hasAnnounce: false)
        XCTAssertFalse(without.contains("announce field"))
        XCTAssertTrue(without.contains("exactly once"))
    }
}
