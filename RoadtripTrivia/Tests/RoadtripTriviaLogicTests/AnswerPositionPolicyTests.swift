import XCTest
@testable import RoadtripTriviaLogic

final class AnswerPositionPolicyTests: XCTestCase {

    func test_modelAlwaysMarksD_balancedDeckSpreadsTheKey() {
        let questions = (0..<8).map { index in
            AnswerPositionPolicy.Question(
                questionText: "Question \(index)?",
                options: ["A: one", "B: two", "C: three", "D: answer\(index)"],
                correctAnswer: "D"
            )
        }
        let moved = AnswerPositionPolicy.redistribute(
            questions,
            targets: [0, 1, 2, 3, 0, 1, 2, 3]
        )
        XCTAssertEqual(moved.map(\.correctAnswer), ["A", "B", "C", "D", "A", "B", "C", "D"])
        XCTAssertEqual(moved[0].options?.first, "A: answer0")
        XCTAssertEqual(moved[1].options?[1], "B: answer1")
        XCTAssertEqual(moved[2].options?[2], "C: answer2")
        XCTAssertEqual(moved[3].options?[3], "D: answer3")
        XCTAssertFalse(moved[0].options?.contains("D: answer0") ?? true)
    }

    func test_fullAnswerTextSittingOnD_isMovedWithItsWords() {
        let question = AnswerPositionPolicy.Question(
            questionText: "Deepest point?",
            options: ["A: Puerto Rico", "B: Tonga", "C: Java", "D: Mariana Trench"],
            correctAnswer: "Mariana Trench"
        )
        let moved = AnswerPositionPolicy.redistribute([question], targets: [0])
        XCTAssertEqual(moved[0].correctAnswer, "A")
        XCTAssertEqual(moved[0].options?.first, "A: Mariana Trench")
        XCTAssertEqual(moved[0].options?.last, "D: Puerto Rico")
    }

    func test_labeledAnswerIsMatchedByTextNotOnlyByLetter() {
        let index = AnswerPositionPolicy.correctOptionIndex(
            correctAnswer: "B: Hawaii",
            options: ["A: Alaska", "D: Maine", "C: Florida", "B: Hawaii"]
        )
        XCTAssertEqual(index, 3)
    }

    func test_plainWordThatStartsWithALetterIsNotTreatedAsALabel() {
        XCTAssertEqual(AnswerPositionPolicy.optionBody("Canada"), "Canada")
        XCTAssertEqual(AnswerPositionPolicy.optionBody("D: Mariana Trench"), "Mariana Trench")
        XCTAssertEqual(AnswerPositionPolicy.optionBody("(C) Sarajevo"), "Sarajevo")
    }

    func test_unmatchedFreeResponseIsLeftAlone() {
        let question = AnswerPositionPolicy.Question(
            questionText: "Capital of Norway?",
            options: nil,
            correctAnswer: "Oslo"
        )
        let moved = AnswerPositionPolicy.redistribute([question], targets: [0])
        XCTAssertEqual(moved, [question])
    }

    func test_balancedDeckUsesEachLetterEvenly() {
        struct Seeded: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state = state &* 6364136223846793005 &+ 1
                return state
            }
        }
        var rng = Seeded(state: 42)
        let targets = AnswerPositionPolicy.balancedTargets(count: 20, random: &rng)
        let counts = Dictionary(grouping: targets, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(targets.count, 20)
        XCTAssertEqual(counts[0], 5)
        XCTAssertEqual(counts[1], 5)
        XCTAssertEqual(counts[2], 5)
        XCTAssertEqual(counts[3], 5)
    }

    func test_fiveQuestionRoundDoesNotRepeatOneLetterMoreThanTwice() {
        struct Seeded: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state = state &* 6364136223846793005 &+ 1
                return state
            }
        }
        var rng = Seeded(state: 7)
        let targets = AnswerPositionPolicy.balancedTargets(count: 5, random: &rng)
        let maxCount = Dictionary(grouping: targets, by: { $0 }).values.map(\.count).max() ?? 0
        XCTAssertEqual(targets.count, 5)
        XCTAssertLessThanOrEqual(maxCount, 2)
        XCTAssertTrue(targets.allSatisfy { (0..<4).contains($0) })
    }
}
