import XCTest
@testable import RoadtripTriviaLogic

final class QuestionDedupPolicyTests: XCTestCase {

    func test_paraphrasedLargestDesertIsDuplicate() {
        let history = ["the largest hot desert in the world | B: Sahara"]
        XCTAssertTrue(
            QuestionDedupPolicy.isNearDuplicate(
                questionText: "Which desert is the largest hot desert on Earth?",
                history: history
            )
        )
    }

    func test_gobiFactIsNotLargestDesertDuplicate() {
        let history = ["The Gobi Desert spans parts of which two countries | China and Mongolia"]
        XCTAssertFalse(
            QuestionDedupPolicy.isNearDuplicate(
                questionText: "Which desert is the largest hot desert on Earth?",
                history: history
            )
        )
    }

    func test_unrelatedGeographyIsNotDuplicate() {
        let history = ["the capital city of Norway | A"]
        XCTAssertFalse(
            QuestionDedupPolicy.isNearDuplicate(
                questionText: "Which desert is the largest hot desert on Earth?",
                history: history
            )
        )
    }

    func test_filterDropsDuplicateButKeepsMinimum() {
        let questions = [
            "What is the capital city of Norway?",
            "Which mountain range acts as the border between France and Spain?",
            "Norfolk County, where Needham is located, is part of which state?",
            "What river is the longest in the world by most geographers?",
            "Which desert is the largest hot desert on Earth?",
        ]
        let history = ["the largest hot desert in the world | B: Sahara"]
        let kept = QuestionDedupPolicy.filterQuestions(
            questions,
            text: { $0 },
            history: history,
            keepAtLeast: 4
        )
        XCTAssertEqual(kept.count, 4)
        XCTAssertFalse(kept.contains { $0.lowercased().contains("largest hot desert") })
    }

    func test_standardRoundKeepsAllFiveEvenWhenOneIsANearDuplicate() {
        let questions = [
            "What is the capital city of Norway?",
            "Which mountain range acts as the border between France and Spain?",
            "Norfolk County, where Needham is located, is part of which state?",
            "What river is the longest in the world by most geographers?",
            "Which desert is the largest hot desert on Earth?",
        ]
        let history = ["the largest hot desert in the world | B: Sahara"]
        let kept = QuestionDedupPolicy.filterQuestions(
            questions,
            text: { $0 },
            history: history,
            keepAtLeast: 5
        )
        XCTAssertEqual(kept.count, 5)
    }

    func test_topicKeyExtractsContentWords() {
        let key = QuestionDedupPolicy.topicKey(
            from: "the largest hot desert in the world | B: Sahara"
        )
        XCTAssertTrue(key.contains("largest"))
        XCTAssertTrue(key.contains("desert"))
        XCTAssertFalse(key.contains("the"))
    }

    func test_historyWithTopicKeysAddsLabeledLine() {
        let history = ["the largest hot desert in the world | B: Sahara"]
        let expanded = QuestionDedupPolicy.historyWithTopicKeys(history)
        XCTAssertTrue(expanded.contains { $0.hasPrefix("TOPIC:") && $0.contains("largest") })
    }
}
