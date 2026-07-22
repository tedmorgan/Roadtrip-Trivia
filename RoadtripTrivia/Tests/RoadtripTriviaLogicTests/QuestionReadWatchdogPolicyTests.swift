import XCTest
@testable import RoadtripTriviaLogic

final class QuestionReadWatchdogPolicyTests: XCTestCase {

    // MARK: - Skip cases

    func test_skipsWhenSessionIsDead() {
        let action = QuestionReadWatchdogPolicy.decide(
            sessionAlive: false,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: 10.0,
            silenceThreshold: 3.0
        )
        XCTAssertEqual(action, .skip(reason: "session ended"))
    }

    /// Regression: an old QREAD scheduled before the last question's
    /// `report_score` could fire while `pendingNoRoundsEnd` was already
    /// driving the conversation, sending a `responseCreate` that would
    /// step on the farewell chain. The policy must skip in that state.
    func test_skipsDuringNoRoundsEndFarewell() {
        let action = QuestionReadWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: true,
            phase: .speaking,
            secondsSinceLastAudioDelta: 5.0,
            silenceThreshold: 3.0
        )
        XCTAssertEqual(action, .skip(reason: "no-rounds-end owns nudging"))
    }

    func test_skipsForIneligiblePhase() {
        for phase in [QuestionReadPhase.ineligible] {
            let action = QuestionReadWatchdogPolicy.decide(
                sessionAlive: true,
                pendingNoRoundsEnd: false,
                phase: phase,
                secondsSinceLastAudioDelta: 10.0,
                silenceThreshold: 3.0
            )
            XCTAssertEqual(action, .skip(reason: "phase not eligible"))
        }
    }

    /// THE 3.log REGRESSION. With a 1.5 s silence threshold, the watchdog
    /// fired during a natural 2.65–2.9 s mid-question pause and sent
    /// `responseCancel`, chopping the host off mid-read. With the relaxed
    /// 3.0 s threshold, that same gap should be ignored — let the AI
    /// finish its sentence.
    func test_skipsWhenAudioStreamedWithinThreshold_3s_threshold() {
        for gap in [0.0, 0.5, 1.5, 2.4, 2.65, 2.9, 2.99] {
            let action = QuestionReadWatchdogPolicy.decide(
                sessionAlive: true,
                pendingNoRoundsEnd: false,
                phase: .speaking,
                secondsSinceLastAudioDelta: gap,
                silenceThreshold: 3.0
            )
            if case .skip = action { } else {
                XCTFail("expected .skip for gap=\(gap)s under 3.0s threshold, got \(action)")
            }
        }
    }

    // MARK: - Fire cases

    /// AI never started speaking (phase still `.listening`) — soft
    /// `responseCreate` is the right action; there's no in-flight turn
    /// to cancel.
    func test_firesSoftWhenListeningAndSilenceExceedsThreshold() {
        let action = QuestionReadWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: .infinity, // never streamed
            silenceThreshold: 3.0
        )
        XCTAssertEqual(action, .fireSoftNudge)
    }

    /// AI emitted a brief audio burst then froze without
    /// `responseAudioDone` (the R1Q2 600ms-then-stuck case). The dead
    /// turn has to be cleared before a new instruction will land.
    func test_firesStuckRecoveryWhenSpeakingButLongSilent() {
        // 4 s gap with phase `.speaking` and 3 s threshold.
        let action = QuestionReadWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .speaking,
            secondsSinceLastAudioDelta: 4.0,
            silenceThreshold: 3.0
        )
        XCTAssertEqual(action, .fireStuckSpeakingRecovery)
    }

    func test_firesSoftForOtherPhase() {
        // `.other` covers `.playing`, `.waiting`, `.showingResult`. No in-
        // flight turn either, so soft nudge is correct.
        let action = QuestionReadWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .other,
            secondsSinceLastAudioDelta: 5.0,
            silenceThreshold: 3.0
        )
        XCTAssertEqual(action, .fireSoftNudge)
    }

    // MARK: - Threshold boundary

    /// Boundary: comparison is strict `<`. A gap exactly at the
    /// threshold means we crossed it — fire. Strictly less skips.
    func test_thresholdBoundaryIsStrictLessThan() {
        let justUnder = QuestionReadWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: 2.999,
            silenceThreshold: 3.0
        )
        if case .skip = justUnder { } else {
            XCTFail("just-under threshold should skip, got \(justUnder)")
        }

        let atThreshold = QuestionReadWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: 3.0,
            silenceThreshold: 3.0
        )
        XCTAssertEqual(atThreshold, .fireSoftNudge,
                       "at-threshold (strict <) should fire — gap is no longer 'within' window")
    }

    func test_thresholdIsConfigurable() {
        // Verify the policy honors a different threshold value (regression
        // guard if we tune the constant in the future).
        let actionStrict = QuestionReadWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: 1.6,
            silenceThreshold: 1.5
        )
        XCTAssertEqual(actionStrict, .fireSoftNudge,
                       "with 1.5s threshold, 1.6s gap should fire (legacy behavior)")

        let actionLoose = QuestionReadWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: 1.6,
            silenceThreshold: 3.0
        )
        if case .skip = actionLoose { } else {
            XCTFail("with 3.0s threshold, 1.6s gap should skip, got \(actionLoose)")
        }
    }

    // MARK: - Precedence

    /// Skip-reasons must be checked in order: session > farewell >
    /// phase > silence. This locks in the priority so future tweaks
    /// don't accidentally let a no-rounds-end watchdog through.
    func test_sessionSkipPrecedenceOverEverythingElse() {
        let action = QuestionReadWatchdogPolicy.decide(
            sessionAlive: false,
            pendingNoRoundsEnd: true,
            phase: .speaking,
            secondsSinceLastAudioDelta: 0.0,
            silenceThreshold: 3.0
        )
        XCTAssertEqual(action, .skip(reason: "session ended"))
    }

    func test_farewellSkipPrecedenceOverPhaseAndSilence() {
        let action = QuestionReadWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: true,
            phase: .speaking,
            secondsSinceLastAudioDelta: 100.0,
            silenceThreshold: 3.0
        )
        XCTAssertEqual(action, .skip(reason: "no-rounds-end owns nudging"))
    }

    // MARK: - infinite silence

    /// `.infinity` silence (lastAudioDeltaAt = nil) means the AI never
    /// produced any audio for this serve. Phase remains `.listening`,
    /// so a soft nudge is right — no in-flight turn to cancel.
    func test_infiniteSilenceWithListeningFiresSoft() {
        let action = QuestionReadWatchdogPolicy.decide(
            sessionAlive: true,
            pendingNoRoundsEnd: false,
            phase: .listening,
            secondsSinceLastAudioDelta: .infinity,
            silenceThreshold: 3.0
        )
        XCTAssertEqual(action, .fireSoftNudge)
    }
}
