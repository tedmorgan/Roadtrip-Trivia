import XCTest
@testable import RoadtripTriviaLogic

final class FarewellEndGamePolicyTests: XCTestCase {

    // MARK: - Disconnect-before-gameOver ordering (5.log regression)

    /// THE 5.log REGRESSION (2026-05-07). `triggerInternalEndGame`
    /// called `.gameOver` transition BEFORE `disconnect()`. UI
    /// observers reacted to `.gameOver` and called `disconnect()`
    /// within 56ms — before the audio drain grace period. Farewell
    /// audio was cut off every time.
    ///
    /// Contract: disconnect MUST happen before gameOver transition.
    func test_disconnectMustPrecedeGameOverTransition() {
        let correctOrder: [FarewellEndGamePolicy.EndGameStep] = [
            .cleanupState,
            .disconnectWebSocket,
            .endSession,
            .transitionToGameOver
        ]
        XCTAssertTrue(
            FarewellEndGamePolicy.isDisconnectBeforeGameOver(steps: correctOrder),
            "disconnect() MUST be called before .gameOver transition to prevent UI observers from tearing down audio prematurely"
        )
    }

    /// If someone reverses the order (the old bug), this test catches it.
    func test_gameOverBeforeDisconnect_isRejected() {
        let wrongOrder: [FarewellEndGamePolicy.EndGameStep] = [
            .cleanupState,
            .endSession,
            .transitionToGameOver,
            .disconnectWebSocket
        ]
        XCTAssertFalse(
            FarewellEndGamePolicy.isDisconnectBeforeGameOver(steps: wrongOrder),
            "Putting .gameOver before disconnect causes the 5.log regression — must be rejected"
        )
    }

    /// Edge case: missing disconnect step entirely.
    func test_missingDisconnect_isRejected() {
        let noDisconnect: [FarewellEndGamePolicy.EndGameStep] = [
            .cleanupState,
            .endSession,
            .transitionToGameOver
        ]
        XCTAssertFalse(FarewellEndGamePolicy.isDisconnectBeforeGameOver(steps: noDisconnect))
    }

    /// Edge case: missing gameOver step entirely.
    func test_missingGameOver_isRejected() {
        let noGameOver: [FarewellEndGamePolicy.EndGameStep] = [
            .cleanupState,
            .disconnectWebSocket,
            .endSession
        ]
        XCTAssertFalse(FarewellEndGamePolicy.isDisconnectBeforeGameOver(steps: noGameOver))
    }

    // MARK: - Post-score watchdog thresholds

    /// History: the 5.log regression (2026-05-07) capped these at 3.5s to
    /// kill 5-second dead pauses. The 6.log freeze cascade (2026-06-11)
    /// showed 3.5s fires during HEALTHY verdict composition (4-6s
    /// time-to-first-audio after a tool response) and the nudge killed
    /// the session — dead air is now prevented by PostScoreWatchdogPolicy's
    /// tool-quiet gate instead of a tight timeout. Current contract:
    /// 7.0s initial / 5.0s continuation.
    func test_currentThresholdsAreAcceptable() {
        XCTAssertTrue(
            FarewellEndGamePolicy.areThresholdsAcceptable(
                initialSilence: FarewellEndGamePolicy.maxPostScoreInitialSilenceSeconds,
                continuationSilence: FarewellEndGamePolicy.maxPostScoreContinuationSilenceSeconds
            ),
            "the contract's own limits must always pass — the coordinator uses them directly and asserts this at init (CarPlay crashed on 2026-06-12 when they diverged)"
        )
    }

    func test_initialAboveMax_isRejected() {
        XCTAssertFalse(
            FarewellEndGamePolicy.areThresholdsAcceptable(
                initialSilence: 7.5,
                continuationSilence: 3.0
            )
        )
    }

    func test_continuationAboveMax_isRejected() {
        XCTAssertFalse(
            FarewellEndGamePolicy.areThresholdsAcceptable(
                initialSilence: 3.0,
                continuationSilence: 5.5
            )
        )
    }

    func test_tighterThresholds_areAcceptable() {
        XCTAssertTrue(
            FarewellEndGamePolicy.areThresholdsAcceptable(
                initialSilence: 2.5,
                continuationSilence: 2.5
            )
        )
    }

    /// The initial threshold must not balloon past the point where a
    /// genuinely wedged turn takes ~10s+ to surface. 7.0 was a deliberate
    /// trade (see PostScoreWatchdogPolicy tool-quiet gate); anything
    /// higher needs a new justification, not a quiet constant bump.
    func test_limitsThemselvesStayReasonable() {
        XCTAssertLessThanOrEqual(FarewellEndGamePolicy.maxPostScoreInitialSilenceSeconds, 7.0)
        XCTAssertLessThanOrEqual(FarewellEndGamePolicy.maxPostScoreContinuationSilenceSeconds, 5.0)
    }

    // MARK: - Step ordering is Comparable

    func test_stepOrdering() {
        XCTAssertTrue(FarewellEndGamePolicy.EndGameStep.cleanupState < .disconnectWebSocket)
        XCTAssertTrue(FarewellEndGamePolicy.EndGameStep.disconnectWebSocket < .endSession)
        XCTAssertTrue(FarewellEndGamePolicy.EndGameStep.endSession < .transitionToGameOver)
    }
}
