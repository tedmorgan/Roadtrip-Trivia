import XCTest
@testable import RoadtripTriviaLogic

final class EndGamePolicyTests: XCTestCase {

    // MARK: - Defer-during-farewell precedence

    /// pendingNoRoundsEnd wins over everything else: the app is
    /// already tearing down via the silence timer, and an immediate
    /// honor would chop off the goodbye.
    func test_defersWhenPendingNoRoundsEnd() {
        let action = EndGamePolicy.decide(
            pendingNoRoundsEnd: true,
            sessionAlive: true,
            canPlayRound: true,
            lightningExpiredWithRoundsRemainingSecondsAgo: .infinity,
            isLightningRound: false,
            roundAnswered: 5,
            endGameConfirmationPending: false,
            playerRequestedEndGame: false
        )
        XCTAssertEqual(action, .deferDuringFarewell)
    }

    func test_defersDuringFarewellEvenIfPlayerRequestedEndGame() {
        // The farewell flow is already responding to the player's
        // request; honoring again would race the silence timer.
        let action = EndGamePolicy.decide(
            pendingNoRoundsEnd: true,
            sessionAlive: true,
            canPlayRound: false,
            lightningExpiredWithRoundsRemainingSecondsAgo: .infinity,
            isLightningRound: false,
            roundAnswered: 5,
            endGameConfirmationPending: false,
            playerRequestedEndGame: true
        )
        XCTAssertEqual(action, .deferDuringFarewell)
    }

    // MARK: - Player explicitly said end-game (5.log / 6.log regression)

    /// Regression from 5.log + 6.log: player said "no, let's end
    /// game", host kept asking "are you sure?". Once the input
    /// transcript flag is set, the next end_game must be honored
    /// without any further confirmation.
    func test_honorsWhenPlayerExplicitlyRequestedEnd() {
        let action = EndGamePolicy.decide(
            pendingNoRoundsEnd: false,
            sessionAlive: true,
            canPlayRound: true,
            lightningExpiredWithRoundsRemainingSecondsAgo: .infinity,
            isLightningRound: false,
            roundAnswered: 3,
            endGameConfirmationPending: false,
            playerRequestedEndGame: true
        )
        XCTAssertEqual(action, .honor,
                       "player intent latch must override the rounds-remain reject")
    }

    // MARK: - Lightning timer race window

    func test_rejectsLightningRaceWithinWindow() {
        let action = EndGamePolicy.decide(
            pendingNoRoundsEnd: false,
            sessionAlive: true,
            canPlayRound: true,
            lightningExpiredWithRoundsRemainingSecondsAgo: 5.0, // < 10
            isLightningRound: false,
            roundAnswered: 0,
            endGameConfirmationPending: false,
            playerRequestedEndGame: false
        )
        XCTAssertEqual(action, .rejectLightningRace)
    }

    func test_doesNotRejectLightningRaceAfterWindow() {
        let action = EndGamePolicy.decide(
            pendingNoRoundsEnd: false,
            sessionAlive: true,
            canPlayRound: true,
            lightningExpiredWithRoundsRemainingSecondsAgo: 15.0, // > 10
            isLightningRound: false,
            roundAnswered: 0,
            endGameConfirmationPending: false,
            playerRequestedEndGame: false
        )
        // Falls through to the broader "rounds remain" guard.
        XCTAssertEqual(action, .rejectAndAskForConfirmation)
    }

    func test_lightningRaceWindowIsConfigurable() {
        let action = EndGamePolicy.decide(
            pendingNoRoundsEnd: false,
            sessionAlive: true,
            canPlayRound: true,
            lightningExpiredWithRoundsRemainingSecondsAgo: 8.0,
            lightningExpiryRaceWindow: 5.0, // tighter window
            isLightningRound: false,
            roundAnswered: 0,
            endGameConfirmationPending: false,
            playerRequestedEndGame: false
        )
        XCTAssertEqual(action, .rejectAndAskForConfirmation,
                       "8s elapsed > 5s window — should fall through")
    }

    // MARK: - Rounds remain mid-round

    func test_rejectsAndAsksForConfirmationMidRound() {
        let action = EndGamePolicy.decide(
            pendingNoRoundsEnd: false,
            sessionAlive: true,
            canPlayRound: true,
            lightningExpiredWithRoundsRemainingSecondsAgo: .infinity,
            isLightningRound: false,
            roundAnswered: 2, // mid-round
            endGameConfirmationPending: false,
            playerRequestedEndGame: false
        )
        XCTAssertEqual(action, .rejectAndAskForConfirmation)
    }

    func test_honorsAfterPlayerConfirmsViaSecondCall() {
        // First end_game was rejected with .rejectAndAskForConfirmation,
        // setting endGameConfirmationPending=true. A subsequent
        // end_game is the player saying yes.
        let action = EndGamePolicy.decide(
            pendingNoRoundsEnd: false,
            sessionAlive: true,
            canPlayRound: true,
            lightningExpiredWithRoundsRemainingSecondsAgo: .infinity,
            isLightningRound: false,
            roundAnswered: 2,
            endGameConfirmationPending: true,
            playerRequestedEndGame: false
        )
        XCTAssertEqual(action, .honor)
    }

    // MARK: - Completed standard round (5.log specific)

    /// 5.log regression: at the END of a standard round (5/5
    /// answered), the player said "stop". The old broader guard
    /// rejected that end_game asking "want to continue or stop?"
    /// even though the player already said stop. The fix: don't
    /// apply the rounds-remain reject after a completed standard
    /// round — the system prompt only allows end_game in that
    /// context when the player literally said stop.
    func test_honorsAfterCompletedStandardRound() {
        let action = EndGamePolicy.decide(
            pendingNoRoundsEnd: false,
            sessionAlive: true,
            canPlayRound: true, // rounds left, but...
            lightningExpiredWithRoundsRemainingSecondsAgo: .infinity,
            isLightningRound: false,
            roundAnswered: 5, // ...standard round just completed
            endGameConfirmationPending: false,
            playerRequestedEndGame: false
        )
        XCTAssertEqual(action, .honor,
                       "after a completed standard round, end_game means the player chose to stop")
    }

    func test_lightningRoundDoesNotShortCircuitAtFiveAnswers() {
        // Lightning rounds aren't "completed" at 5 answers — they
        // run for a fixed time. So the rounds-remain guard still
        // applies.
        let action = EndGamePolicy.decide(
            pendingNoRoundsEnd: false,
            sessionAlive: true,
            canPlayRound: true,
            lightningExpiredWithRoundsRemainingSecondsAgo: .infinity,
            isLightningRound: true,
            roundAnswered: 5,
            endGameConfirmationPending: false,
            playerRequestedEndGame: false
        )
        XCTAssertEqual(action, .rejectAndAskForConfirmation)
    }

    // MARK: - No rounds remain

    func test_honorsWhenNoRoundsRemain() {
        let action = EndGamePolicy.decide(
            pendingNoRoundsEnd: false,
            sessionAlive: true,
            canPlayRound: false,
            lightningExpiredWithRoundsRemainingSecondsAgo: .infinity,
            isLightningRound: false,
            roundAnswered: 5,
            endGameConfirmationPending: false,
            playerRequestedEndGame: false
        )
        XCTAssertEqual(action, .honor)
    }

    // MARK: - Session torn down

    func test_honorsWhenSessionAlreadyEnded() {
        // Edge case: AI fires end_game late, after we already tore
        // down. We honor (it's a no-op essentially).
        let action = EndGamePolicy.decide(
            pendingNoRoundsEnd: false,
            sessionAlive: false,
            canPlayRound: true,
            lightningExpiredWithRoundsRemainingSecondsAgo: .infinity,
            isLightningRound: false,
            roundAnswered: 0,
            endGameConfirmationPending: false,
            playerRequestedEndGame: false
        )
        XCTAssertEqual(action, .honor)
    }
}
