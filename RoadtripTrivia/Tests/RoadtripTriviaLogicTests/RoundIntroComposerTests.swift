import XCTest
@testable import RoadtripTriviaLogic

/// Fixtures for app-owned round announcements. Encodes the recurring
/// "Round 5 played as a normal round / lightning never announced" defects.
final class RoundIntroComposerTests: XCTestCase {

    func test_lightningIntroAlwaysSaysLightningRound() {
        let line = RoundIntroComposer.compose(
            roundNumber: 5, category: "Geography",
            isLightning: true, locationLabel: "Cape Cod"
        )
        XCTAssertTrue(line.contains("Lightning Round"),
                      "the player MUST be told the format is changing")
        XCTAssertTrue(line.contains("5"))
        XCTAssertTrue(line.contains("Geography"))
    }

    func test_standardIntroNamesRoundAndCategory() {
        let line = RoundIntroComposer.compose(
            roundNumber: 3, category: "Music",
            isLightning: false, locationLabel: nil
        )
        XCTAssertTrue(line.contains("Round 3"))
        XCTAssertTrue(line.contains("Music"))
        XCTAssertFalse(line.contains("Lightning"))
    }

    func test_standardIntroWeavesInLocationWhenAvailable() {
        let line = RoundIntroComposer.compose(
            roundNumber: 2, category: "Landmarks",
            isLightning: false, locationLabel: "Needham, MA"
        )
        XCTAssertTrue(line.contains("Needham, MA"))
    }
}
