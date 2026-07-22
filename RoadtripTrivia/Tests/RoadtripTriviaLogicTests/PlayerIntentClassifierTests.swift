import XCTest
@testable import RoadtripTriviaLogic

final class PlayerIntentClassifierTests: XCTestCase {

    // MARK: - Explicit end-game phrases

    func test_classifiesExplicitEndGamePhrases() {
        let phrases = [
            "let's end the game",
            "I'd like to end game now",
            "stop game please",
            "let's stop the game",
            "stop playing",
            "I'm done playing",
            "I quit",
            "okay I'm done",
        ]
        for p in phrases {
            XCTAssertEqual(PlayerIntentClassifier.classifyEndGame(p), .explicit,
                           "expected .explicit for: \(p)")
        }
    }

    func test_classifiesExplicitEndGameRegardlessOfCaseOrPunctuation() {
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame("End game!"), .explicit)
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame("END THE GAME."), .explicit)
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame("Yeah, let's stop playing."), .explicit)
    }

    // MARK: - Soft no (between-rounds context)

    /// The 5.log/6.log regression: between rounds, the host asks
    /// "Want to keep going?" Player says "no". The classifier must
    /// signal `.softNo` so the coordinator can latch the player's
    /// intent. Coordinator gates on `isBetweenRoundsStopWindow`
    /// before treating this as end-game.
    func test_classifiesSoftNoBetweenRounds() {
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame("no"), .softNo)
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame("Nope."), .softNo)
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame("nah, I'm good"), .softNo)
    }

    /// "no more" is ambiguous mid-round ("no more hints"), so it is a SOFT
    /// decline (between-rounds only) rather than an always-honored explicit
    /// quit. The coordinator now honors `.explicit` mid-round, so keeping
    /// "no more" soft prevents "no more hints" from ending the game.
    func test_noMoreIsSoftNotExplicit() {
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame("no more for me"), .softNo)
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame("no more hints please"), .softNo)
    }

    // MARK: - None — must NOT trigger end-game

    func test_doesNotMatchUnrelatedPhrases() {
        let phrases = [
            "the answer is rugby",
            "I think it's option B",
            "yes please",
            "let's go to the next question",
            "give me a hint",
        ]
        for p in phrases {
            XCTAssertEqual(PlayerIntentClassifier.classifyEndGame(p), .none,
                           "expected .none for: \(p)")
        }
    }

    func test_doesNotFalsePositiveOnSubstringsOfWords() {
        // "Quito" must not match "quit". "Stopping by" must not
        // match "stop". The classifier pads with spaces, so these
        // are guaranteed safe.
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame("Quito is the capital"), .none)
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame("stopwatch"), .none)
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame("noted"), .none)
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame("tornado"), .none)
    }

    func test_emptyStringIsNone() {
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame(""), .none)
        XCTAssertEqual(PlayerIntentClassifier.classifyEndGame("   "), .none)
    }

    // MARK: - Backwards-compat boolean

    func test_transcriptRequestsEndGameMatchesAnyNonNoneSignal() {
        XCTAssertTrue(PlayerIntentClassifier.transcriptRequestsEndGame("stop playing"))
        XCTAssertTrue(PlayerIntentClassifier.transcriptRequestsEndGame("no"))
        XCTAssertFalse(PlayerIntentClassifier.transcriptRequestsEndGame("the answer is rugby"))
    }
}
