import XCTest
@testable import RoadtripTriviaLogic

/// Regression fixtures for the "host cut off mid-sentence" family.
/// Each test is named for the real-world trace it encodes.
final class BargeInPolicyTests: XCTestCase {

    // The canonical cut-off: host is speaking (mic muted client-side), a
    // stale/echo-triggered `interrupted` event arrives from the server.
    // Honoring it killed playback mid-question in build after build.
    func test_interruptedWhileMicMuted_isIgnored() {
        let verdict = BargeInPolicy.decide(
            micMuted: true,
            utteranceLockActive: false,
            secondsSinceLocalVoice: 0.5
        )
        XCTAssertEqual(verdict, .ignoreMicMuted,
                       "no live audio was being sent — interruption must be stale/echo")
    }

    // debug-f3b222 3.log / 6.log: residual pipeline audio fired VAD during
    // the farewell, chopping the purchase CTA. The utterance lock wins over
    // everything, including genuine-looking voice.
    func test_interruptedDuringUtteranceLock_isIgnored_evenWithRecentVoice() {
        let verdict = BargeInPolicy.decide(
            micMuted: false,
            utteranceLockActive: true,
            secondsSinceLocalVoice: 0.1
        )
        XCTAssertEqual(verdict, .ignoreUtteranceLock)
    }

    // Mic open (awaiting answer) but our client-side energy detector heard
    // nothing voice-like — the server VAD tripped on road noise. Don't kill
    // the chime/gong or any trailing host audio for it.
    func test_interruptedWithoutLocalVoiceCorroboration_isIgnored() {
        XCTAssertEqual(
            BargeInPolicy.decide(micMuted: false, utteranceLockActive: false,
                                 secondsSinceLocalVoice: nil),
            .ignoreNoLocalVoice
        )
        XCTAssertEqual(
            BargeInPolicy.decide(micMuted: false, utteranceLockActive: false,
                                 secondsSinceLocalVoice: 10.0),
            .ignoreNoLocalVoice,
            "stale voice (10s ago) does not corroborate a barge-in now"
        )
    }

    // The genuine case: mic open, we heard the player speak moments ago.
    func test_genuineBargeIn_isHonored() {
        let verdict = BargeInPolicy.decide(
            micMuted: false,
            utteranceLockActive: false,
            secondsSinceLocalVoice: 0.8
        )
        XCTAssertEqual(verdict, .honor)
    }

    func test_corroborationWindowBoundary() {
        XCTAssertEqual(
            BargeInPolicy.decide(micMuted: false, utteranceLockActive: false,
                                 secondsSinceLocalVoice: BargeInPolicy.corroborationWindowSeconds),
            .honor, "exactly at the window edge still counts"
        )
        XCTAssertEqual(
            BargeInPolicy.decide(micMuted: false, utteranceLockActive: false,
                                 secondsSinceLocalVoice: BargeInPolicy.corroborationWindowSeconds + 0.01),
            .ignoreNoLocalVoice
        )
    }
}
