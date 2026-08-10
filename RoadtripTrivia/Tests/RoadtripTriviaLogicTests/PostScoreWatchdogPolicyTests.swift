import XCTest
@testable import RoadtripTriviaLogic

final class PostScoreWatchdogPolicyTests: XCTestCase {

    // MARK: - Skip cases

    func test_skipsWhenSessionIsDead() {
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: false,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: 10.0,
            reason: .armed
        )
        XCTAssertEqual(action, .skip(reason: "session ended"))
    }

    func test_skipsWhenNoRoundsEndIsActive() {
        // The no-rounds farewell flow owns all nudging; firing here
        // would chop off the goodbye.
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: true,
            phase: .listening,
            secondsSinceLastAudioDelta: 10.0,
            reason: .continuation
        )
        XCTAssertEqual(action, .skip(reason: "no-rounds-end owns nudging"))
    }

    // MARK: - Re-arm cases

    func test_reArmsWhenHostIsSpeaking() {
        // Don't interrupt an ongoing turn — let it finish.
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .speaking,
            secondsSinceLastAudioDelta: 0.05,
            reason: .armed
        )
        if case .reArm = action { } else {
            XCTFail("expected .reArm when host is speaking, got \(action)")
        }
    }

    /// THE 9.log REGRESSION. The post-score continuation watchdog was
    /// firing 1.5 s after `responseAudioDone`, sending `responseCancel`
    /// during the AI's mid-explanation gap. That chopped off the host's
    /// answer-explanation 5 s into a turn. The fix is to suppress the
    /// nudge when audio was streaming recently — phase has moved to
    /// .listening but the AI is just between sub-turns.
    func test_reArmsWhenAudioWasStreamingVeryRecently() {
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: 1.0, // < 2.0 default window
            reason: .continuation
        )
        if case .reArm = action { } else {
            XCTFail("expected .reArm when audio just streamed, got \(action)")
        }
    }

    func test_doesNotReArmWhenAudioGapExceedsWindow() {
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: 2.5, // > 2.0
            reason: .continuation
        )
        XCTAssertEqual(action, .fireSoft,
                       "after the audio window expires, fire soft for continuation")
    }

    func test_recentAudioWindowIsConfigurable() {
        // Verify the boundary works as expected with a custom window.
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: 2.5,
            reason: .continuation,
            recentAudioWindowSeconds: 3.0
        )
        if case .reArm = action { } else {
            XCTFail("with 3.0s window and 2.5s gap, should re-arm")
        }
    }

    // MARK: - Fire cases

    /// The continuation case must NEVER cancel — that's what was
    /// chopping off mid-explanation in 9.log. Soft fire only.
    func test_firesSoftForContinuationReason() {
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: 10.0,
            reason: .continuation
        )
        XCTAssertEqual(action, .fireSoft,
                       "continuation must be soft (no responseCancel) to avoid chopping mid-explanation")
    }

    /// The armed case (no audio at all after report_score) is the
    /// "wedged turn" recovery and escalates (nudge + escalation watchdog).
    func test_firesHardForArmedReason() {
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: .infinity,
            reason: .armed
        )
        XCTAssertEqual(action, .fireHard,
                       "armed (no audio at all) must nudge + escalate to clear stuck turn")
    }

    // MARK: - Tool-quiet window (the 2026-06-11 freeze cascade)

    /// THE 6.log REGRESSION. After `report_score`'s result was submitted,
    /// Gemini silently composed its verdict turn for 4-6s. The watchdog
    /// fired during that window; its nudge interrupted the in-flight
    /// generation, orphaned the pending function call
    /// (toolCallCancellation), the model re-graded, the watchdog
    /// re-fired, and the server closed the session (1001). Recent tool
    /// activity must mean "model alive — re-arm", even with zero audio.
    func test_reArmsWhenToolActivityWasRecent() {
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: .infinity, // no audio at all
            reason: .armed,
            secondsSinceLastToolEvent: 3.7 // result just submitted
        )
        if case .reArm = action { } else {
            XCTFail("expected .reArm during post-tool composition window, got \(action)")
        }
    }

    func test_firesWhenToolActivityIsStale() {
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: .infinity,
            reason: .armed,
            secondsSinceLastToolEvent: 14.0 // > 12.0 default window
        )
        XCTAssertEqual(action, .fireHard,
                       "stale tool activity means a genuinely wedged turn — fire")
    }

    /// THE 2026-06-25 R2Q2 FREEZE. With compression effectively disabled
    /// (full context retained), Gemini's silent post-`report_score`
    /// composition stretched to ~7-12s. Under the old 6s tool-quiet window
    /// the watchdog fired at ~7.3s and its nudge orphaned the in-flight
    /// get_next_question (toolCallCancellation) -> re-score -> freeze.
    /// The widened 12s default must now re-arm at 7-9s instead of firing.
    func test_reArmsDuringLongPostScoreComposition() {
        for gap in [7.0, 9.0, 11.5] {
            let action = PostScoreWatchdogPolicy.decide(
                sessionAlive: true,
                pendingNoRoundsEnd: false,
                phase: .listening,
                secondsSinceLastAudioDelta: .infinity, // no audio yet
                reason: .armed,
                secondsSinceLastToolEvent: gap
            )
            if case .reArm = action { } else {
                XCTFail("tool activity \(gap)s ago should re-arm (model still composing), got \(action)")
            }
        }
    }

    func test_toolQuietWindowIsConfigurable() {
        // The tool-quiet window only gates the `.armed` path, so exercise
        // its configurability there.
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: .infinity,
            reason: .armed,
            secondsSinceLastToolEvent: 8.0,
            toolQuietWindowSeconds: 10.0
        )
        if case .reArm = action { } else {
            XCTFail("with 10s window and 8s gap, should re-arm")
        }
    }

    /// THE 2026-07-31 DEAD-AIR REGRESSION (R2Q3→Q4 / R3Q3→Q4 / R3Q4→Q5).
    /// The tool-quiet window was gating BOTH post-score reasons. In the
    /// `.continuation` window — reached only AFTER `responseAudioDone`, i.e.
    /// the verdict turn already completed — the `report_score` tool event is
    /// still only ~5-11s old, so the 12s window kept re-arming ("model is
    /// composing") until ~16s, producing ~11-14s of dead air before the
    /// host was nudged to call `get_next_question`. Since the verdict
    /// response has completed, there is nothing in-flight to orphan, so the
    /// tool-quiet gate must NOT apply to `.continuation`: fire soft as soon
    /// as audio is quiet.
    func test_continuationFiresAfterVerdictDespiteRecentScore() {
        for toolGap in [5.0, 8.0, 11.0] {
            let action = PostScoreWatchdogPolicy.decide(
                sessionAlive: true,
                pendingNoRoundsEnd: false,
                phase: .listening,
                secondsSinceLastAudioDelta: 2.5, // verdict audio done, quiet
                reason: .continuation,
                secondsSinceLastToolEvent: toolGap // report_score still recent
            )
            XCTAssertEqual(action, .fireSoft,
                           "continuation must fire once audio is quiet — the verdict turn completed, so a recent report_score (\(toolGap)s) must not block the get_next_question nudge")
        }
    }

    /// Guards the asymmetry directly: an identical recent tool gap re-arms
    /// for `.armed` (freeze protection) but fires for `.continuation`
    /// (no in-flight generation to protect).
    func test_toolQuietGateAppliesToArmedButNotContinuation() {
        let armed = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: 2.5,
            reason: .armed,
            secondsSinceLastToolEvent: 6.0
        )
        if case .reArm = armed { } else {
            XCTFail("armed with a 6s tool gap must re-arm (freeze protection), got \(armed)")
        }

        let continuation = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: 2.5,
            reason: .continuation,
            secondsSinceLastToolEvent: 6.0
        )
        XCTAssertEqual(continuation, .fireSoft,
                       "continuation with the same 6s tool gap must fire — verdict already completed")
    }

    func test_noToolActivityEverStillFires() {
        // Default secondsSinceLastToolEvent (.infinity) must not change
        // pre-existing behavior.
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: 10.0,
            reason: .continuation
        )
        XCTAssertEqual(action, .fireSoft)
    }

    // MARK: - Precedence

    /// Multiple suppression conditions in play — `.skip` for the
    /// session-end reason wins, regardless of phase or timing.
    func test_skipPrecedenceOverEverythingElse() {
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: false, // session gone
            pendingNoRoundsEnd: true, // also farewell
            phase: .speaking,        // also speaking
            secondsSinceLastAudioDelta: 0.0, // also recent audio
            reason: .armed
        )
        XCTAssertEqual(action, .skip(reason: "session ended"))
    }

    func test_pendingNoRoundsEndPrecedenceOverPhaseAndTiming() {
        let action = PostScoreWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: true,
            phase: .listening,
            secondsSinceLastAudioDelta: 100.0,
            reason: .armed
        )
        XCTAssertEqual(action, .skip(reason: "no-rounds-end owns nudging"))
    }
}
