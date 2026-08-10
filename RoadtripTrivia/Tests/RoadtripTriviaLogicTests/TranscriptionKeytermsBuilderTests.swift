import XCTest
@testable import RoadtripTriviaLogic

final class TranscriptionKeytermsBuilderTests: XCTestCase {

    func test_includesCorrectAnswerAndOptionLetters() {
        let terms = TranscriptionKeytermsBuilder.build(
            questionText: "What is the capital of France?",
            options: ["Paris", "Lyon", "Nice", "Marseille"],
            correctAnswer: "Paris",
            category: "Geography"
        )

        XCTAssertTrue(terms.contains("Paris"))
        XCTAssertTrue(terms.contains("Geography"))
        XCTAssertTrue(terms.contains("A"))
        XCTAssertTrue(terms.contains("B"))
        XCTAssertTrue(terms.contains("Lyon"))
        XCTAssertTrue(terms.contains("A: Paris"))
    }

    func test_deduplicatesCaseInsensitively() {
        let terms = TranscriptionKeytermsBuilder.build(
            questionText: nil,
            options: ["Paris", "paris"],
            correctAnswer: "PARIS",
            category: nil
        )
        let parisCount = terms.filter { $0.lowercased() == "paris" }.count
        XCTAssertEqual(parisCount, 1)
    }

    func test_respectsMaxTermLengthAndCount() {
        let long = String(repeating: "x", count: 80)
        let manyOptions = (0..<40).map { "Option\($0) Value" }
        let terms = TranscriptionKeytermsBuilder.build(
            questionText: long,
            options: manyOptions,
            correctAnswer: long,
            category: long
        )
        XCTAssertLessThanOrEqual(terms.count, TranscriptionKeytermsBuilder.maxTerms)
        XCTAssertTrue(terms.allSatisfy { $0.count <= TranscriptionKeytermsBuilder.maxTermLength })
    }

    func test_emptyInputsYieldEmptyTerms() {
        let terms = TranscriptionKeytermsBuilder.build(
            questionText: nil,
            options: nil,
            correctAnswer: nil,
            category: nil
        )
        XCTAssertTrue(terms.isEmpty)
    }
}
