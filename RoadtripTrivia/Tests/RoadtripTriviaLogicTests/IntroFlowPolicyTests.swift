import XCTest
@testable import RoadtripTriviaLogic

/// Locks the intro lines and timing that build 30–31 got wrong on device.
final class IntroFlowPolicyTests: XCTestCase {

    func test_firstTurnInstructions_requireWelcomeThenTeamNameOnly() {
        let text = IntroFlowPolicy.firstTurnInstructions
        XCTAssertTrue(
            text.contains(IntroFlowPolicy.welcomeLine),
            "first host turn must include the welcome — kickoff used to skip it"
        )
        XCTAssertTrue(text.localizedCaseInsensitiveContains("team name"))
        XCTAssertTrue(text.contains("STOP"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("do not ask ages"))
    }

    func test_welcomeLine_isTheClassicShowOpen() {
        XCTAssertEqual(IntroFlowPolicy.welcomeLine, "Welcome to Roadtrip Trivia!")
    }

    func test_setupCopy_requiresStopAndWaitOnAges() {
        let block = IntroFlowPolicy.newGameSetupBlock
        XCTAssertTrue(block.contains("STOP and wait"))
        XCTAssertTrue(block.localizedCaseInsensitiveContains("exactly once"))
        XCTAssertTrue(block.localizedCaseInsensitiveContains("do not ask ages again"))
        XCTAssertTrue(block.contains("Do NOT skip to difficulty"))
    }

    func test_batchPendingInstruction_doesNotScriptPullUpLine() {
        let text = IntroFlowPolicy.batchPendingInstruction.lowercased()
        XCTAssertTrue(text.contains("great choice"))
        XCTAssertTrue(text.contains("do not mention loading"))
        XCTAssertTrue(text.contains("do not call get_next_question again"))
    }

    func test_round1Nudge_isToolOnly_noPullUpFiller() {
        let text = IntroFlowPolicy.round1NudgeInstructions.lowercased()
        XCTAssertTrue(text.contains("get_next_question"))
        XCTAssertTrue(text.contains("do not speak first") || text.contains("tool call only"))
        XCTAssertTrue(text.contains("pull up")) // forbidden phrase named so the model avoids it
        XCTAssertTrue(IntroFlowPolicy.doNotAnnounceLoading.lowercased().contains("pulling up"))
    }

    func test_setupNudge_doesNotFireBeforeThirdHostTurn() {
        XCTAssertNil(IntroFlowPolicy.timeoutAfterHostTurn(hostTurnsCompleted: 1))
        XCTAssertNil(IntroFlowPolicy.timeoutAfterHostTurn(hostTurnsCompleted: 2))
        XCTAssertEqual(IntroFlowPolicy.timeoutAfterHostTurn(hostTurnsCompleted: 3), 20)
    }

    func test_setupNudge_ignoresPlayerStops_untilAfterThirdHostTurn() {
        XCTAssertNil(
            IntroFlowPolicy.delayAfterPlayerStop(
                hostTurnsCompleted: 1,
                playerStopsAfterThirdHostTurn: 3
            ),
            "three early VAD stops must not skip the ages question"
        )
        XCTAssertNil(
            IntroFlowPolicy.delayAfterPlayerStop(
                hostTurnsCompleted: 3,
                playerStopsAfterThirdHostTurn: 0
            )
        )
        XCTAssertEqual(
            IntroFlowPolicy.delayAfterPlayerStop(
                hostTurnsCompleted: 3,
                playerStopsAfterThirdHostTurn: 1
            ),
            4
        )
    }
}
