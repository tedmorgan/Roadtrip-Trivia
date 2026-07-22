import XCTest
@testable import RoadtripTriviaLogic

/// Regression fixtures for "nudge storms": watchdogs firing repeatedly per
/// question, each costing tokens and frequently interrupting a slow-but-
/// healthy turn (the fix-a-pause-create-a-cutoff loop documented across
/// ~20 builds in Apr–May 2026).
final class TurnRecoveryGovernorTests: XCTestCase {

    func test_firstNudgeIsAllowed() {
        let state = TurnRecoveryGovernor.State()
        XCTAssertEqual(
            TurnRecoveryGovernor.decide(kind: .softNudge, now: 100, state: state),
            .allow
        )
    }

    func test_backToBackNudgesFromDifferentWatchdogsAreSpaced() {
        // The classic storm: postScore watchdog fires at t=0, questionRead
        // watchdog fires at t=1.5 — previously both went through.
        var state = TurnRecoveryGovernor.State()
        TurnRecoveryGovernor.record(kind: .softNudge, now: 100, state: &state)
        let verdict = TurnRecoveryGovernor.decide(kind: .softNudge, now: 101.5, state: state)
        XCTAssertEqual(verdict, .denySpacing(secondsSinceLast: 1.5))
    }

    func test_nudgeBudgetPerQuestionIsEnforced() {
        var state = TurnRecoveryGovernor.State()
        for i in 0..<3 {
            let now = Double(100 + i * 10)
            XCTAssertEqual(TurnRecoveryGovernor.decide(kind: .softNudge, now: now, state: state), .allow)
            TurnRecoveryGovernor.record(kind: .softNudge, now: now, state: &state)
        }
        XCTAssertEqual(
            TurnRecoveryGovernor.decide(kind: .softNudge, now: 200, state: state),
            .denyNudgeBudget(used: 3),
            "4th nudge for the same question is refused — escalate instead of spamming"
        )
    }

    func test_onlyOneCancelPerQuestion() {
        // `responseCancel` is delivered as a literal "[stop]" user turn —
        // it interrupts the model and pollutes context. One per question, max.
        var state = TurnRecoveryGovernor.State()
        TurnRecoveryGovernor.record(kind: .cancelAndNudge, now: 100, state: &state)
        XCTAssertEqual(
            TurnRecoveryGovernor.decide(kind: .cancelAndNudge, now: 150, state: state),
            .denyCancelBudget(used: 1)
        )
        // A soft nudge is still fine (budget permitting).
        XCTAssertEqual(
            TurnRecoveryGovernor.decide(kind: .softNudge, now: 150, state: state),
            .allow
        )
    }

    func test_reconnectEscalationIsAlwaysAllowed() {
        var state = TurnRecoveryGovernor.State()
        for i in 0..<5 {
            TurnRecoveryGovernor.record(kind: .cancelAndNudge, now: Double(i), state: &state)
        }
        XCTAssertEqual(
            TurnRecoveryGovernor.decide(kind: .reconnectEscalation, now: 5, state: state),
            .allow,
            "when the session is wedged, recovery outranks rate limits"
        )
    }

    func test_newQuestionResetsBudgetsButKeepsSpacing() {
        var state = TurnRecoveryGovernor.State()
        TurnRecoveryGovernor.record(kind: .cancelAndNudge, now: 100, state: &state)
        state.resetForNewQuestion()
        XCTAssertEqual(state.nudgeCount, 0)
        XCTAssertEqual(state.cancelCount, 0)
        // Spacing still applies across the question boundary.
        XCTAssertEqual(
            TurnRecoveryGovernor.decide(kind: .softNudge, now: 101, state: state),
            .denySpacing(secondsSinceLast: 1.0)
        )
        XCTAssertEqual(
            TurnRecoveryGovernor.decide(kind: .softNudge, now: 105, state: state),
            .allow
        )
    }

    /// R3 freeze (debug-f3b222.log 2026-06-24, lines 365–386).
    ///
    /// The freeze loop was: a stuck question-read recovery sent `responseCancel`
    /// → the in-flight `get_next_question` was orphaned (`tool_call_cancelled`)
    /// → the coordinator rewound and RE-SERVED the same question → re-serving
    /// called `resetForNewQuestion()` → the cancel budget went back to 0 → the
    /// watchdog cancelled again. Because every iteration reset the budget, the
    /// `maxCancelsPerQuestion == 1` cap could never trip, so the loop ran until
    /// the player force-quit.
    ///
    /// The fix: a re-serve caused by a `tool_call_cancelled` rewind is recovery,
    /// NOT forward progress, so the coordinator must NOT call
    /// `resetForNewQuestion()` on it. This test pins that invariant: with the
    /// budget preserved across the rewind/re-serve, the second cancel is denied
    /// (which now drives a reconnect escalation instead of another cancel).
    func test_cancelRewindReserveMustNotResetBudget_breaksFreezeLoop() {
        var state = TurnRecoveryGovernor.State()

        // First stuck recovery on this question: a cancel is allowed.
        XCTAssertEqual(
            TurnRecoveryGovernor.decide(kind: .cancelAndNudge, now: 100, state: state),
            .allow
        )
        TurnRecoveryGovernor.record(kind: .cancelAndNudge, now: 100, state: &state)

        // The cancel orphaned the tool call → rewind → SAME question re-served.
        // Correct behavior: budget is NOT reset (no resetForNewQuestion() here).
        // Spacing has elapsed, so spacing is not the thing under test.
        XCTAssertEqual(
            TurnRecoveryGovernor.decide(kind: .cancelAndNudge, now: 110, state: state),
            .denyCancelBudget(used: 1),
            "second cancel for the same re-served question must be refused so the loop can't run forever"
        )
    }

    /// Demonstrates the OLD (buggy) behavior to make the regression explicit:
    /// if the cancel-rewind re-serve had reset the budget, the second cancel
    /// would be wrongly allowed — the infinite loop.
    func test_resettingBudgetOnRewindReserveWouldReopenFreezeLoop() {
        var state = TurnRecoveryGovernor.State()
        TurnRecoveryGovernor.record(kind: .cancelAndNudge, now: 100, state: &state)
        // BUG: treating the rewind re-serve as a brand-new question.
        state.resetForNewQuestion()
        XCTAssertEqual(
            TurnRecoveryGovernor.decide(kind: .cancelAndNudge, now: 110, state: state),
            .allow,
            "this is the loop we fixed: resetting on a recovery re-serve re-arms the cancel budget"
        )
    }
}
