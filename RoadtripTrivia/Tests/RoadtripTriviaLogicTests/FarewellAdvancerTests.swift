import XCTest
@testable import RoadtripTriviaLogic

final class FarewellAdvancerTests: XCTestCase {

    // MARK: - audioDelta

    /// Every audio delta marks the current chunk as having actually
    /// played. The coordinator uses this to gate `responseAudioDone`
    /// progression.
    func test_audioDeltaAlwaysMarksAudioStarted() {
        let state = FarewellState(chainIndex: 1, chainCount: 3, chunkAudioStarted: false)
        XCTAssertEqual(FarewellAdvancer.handle(.audioDelta, state: state), .markAudioStarted)
    }

    func test_audioDeltaMarksAudioStartedEvenIfAlreadyStarted() {
        let state = FarewellState(chainIndex: 1, chainCount: 3, chunkAudioStarted: true)
        XCTAssertEqual(FarewellAdvancer.handle(.audioDelta, state: state), .markAudioStarted)
    }

    // MARK: - audioDone — early (8.log regression)

    /// THE 8.log REGRESSION. Gemini sometimes emits
    /// `responseAudioDone` BEFORE the actual audio starts streaming
    /// for the chunk we sent. If we naively advance, we step on the
    /// previous chunk — which is exactly what cut off the purchase
    /// CTA in `mic_gating 8.log`. The advancer MUST ignore the early
    /// done.
    func test_audioDoneIgnoredBeforeChunkAudioStarted() {
        let state = FarewellState(chainIndex: 1, chainCount: 3, chunkAudioStarted: false)
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .ignoreEarlyDone)
    }

    func test_earlyDoneIgnoredEvenAtChainBoundary() {
        // No off-by-one when the early-done arrives at the last
        // chunk: still ignore, do NOT prematurely arm auto-end.
        let state = FarewellState(chainIndex: 3, chainCount: 3, chunkAudioStarted: false)
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .ignoreEarlyDone)
    }

    // MARK: - audioDone — real (advance)

    /// Real `responseAudioDone` after audio actually played.
    /// Advance to the next chunk in the chain.
    func test_audioDoneAdvancesAfterAudioStarted_midChain() {
        let state = FarewellState(chainIndex: 1, chainCount: 3, chunkAudioStarted: true)
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .sendNextChunk)
    }

    func test_audioDoneAdvancesAfterFirstChunkWithRemaining() {
        let state = FarewellState(chainIndex: 1, chainCount: 3, chunkAudioStarted: true)
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .sendNextChunk)
    }

    // MARK: - audioDone — chain drained

    /// After the LAST chunk plays, there's nothing left to send.
    /// Arm the silence-based auto-end so the session terminates
    /// naturally.
    func test_audioDoneArmsAutoEndAtChainEnd() {
        let state = FarewellState(chainIndex: 3, chainCount: 3, chunkAudioStarted: true)
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .armSilenceAutoEnd)
    }

    func test_audioDoneArmsAutoEndPastChainEnd() {
        // Defensive: chainIndex > chainCount should still arm auto-end.
        let state = FarewellState(chainIndex: 5, chainCount: 3, chunkAudioStarted: true)
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .armSilenceAutoEnd)
    }

    // MARK: - chunkTimeout — 4.log regression

    /// THE 4.log REGRESSION (2026-05-07). Gemini never sent the real
    /// `responseAudioDone` for the last farewell chunk. Every early
    /// done got ignored. The chain stalled, the WS server closed after
    /// its idle timeout, and the farewell was cut off. The per-chunk
    /// timeout MUST force advancement regardless of whether any audio
    /// was received for the chunk.
    func test_chunkTimeoutForcesAdvancement_midChain() {
        // Chunk 2 sent, timeout fires (no real audioDone received).
        let state = FarewellState(chainIndex: 2, chainCount: 3, chunkAudioStarted: false)
        XCTAssertEqual(FarewellAdvancer.handle(.chunkTimeout, state: state), .sendNextChunk)
    }

    func test_chunkTimeoutForcesAdvancement_lastChunk() {
        // Chunk 3 (last) timed out. Must arm auto-end, not stall.
        let state = FarewellState(chainIndex: 3, chainCount: 3, chunkAudioStarted: false)
        XCTAssertEqual(FarewellAdvancer.handle(.chunkTimeout, state: state), .armSilenceAutoEnd)
    }

    func test_chunkTimeoutForces_evenAfterAudioPlayed() {
        // Audio DID play for this chunk but Gemini never sent the
        // done event. Timeout should still force advancement.
        let state = FarewellState(chainIndex: 2, chainCount: 3, chunkAudioStarted: true)
        XCTAssertEqual(FarewellAdvancer.handle(.chunkTimeout, state: state), .sendNextChunk)
    }

    func test_chunkTimeoutArmsAutoEnd_lastChunkWithAudio() {
        let state = FarewellState(chainIndex: 3, chainCount: 3, chunkAudioStarted: true)
        XCTAssertEqual(FarewellAdvancer.handle(.chunkTimeout, state: state), .armSilenceAutoEnd)
    }

    // MARK: - End-to-end sequence — 3-chunk farewell (happy path)

    /// Walk through a full 3-chunk farewell, simulating the events
    /// in the order they actually arrive. This is the canonical
    /// happy path; it must produce: send → done → send → done →
    /// auto-end.
    func test_threeChunkFarewell_endToEnd() {
        var state = FarewellState(chainIndex: 1, chainCount: 3, chunkAudioStarted: false)

        // Chunk 1 sent. Spurious early audio-done arrives first.
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .ignoreEarlyDone)

        // Real audio for chunk 1.
        XCTAssertEqual(FarewellAdvancer.handle(.audioDelta, state: state), .markAudioStarted)
        state.chunkAudioStarted = true

        // Audio for chunk 1 finishes. Advance to chunk 2.
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .sendNextChunk)
        state.chainIndex = 2
        state.chunkAudioStarted = false

        // Spurious early done again.
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .ignoreEarlyDone)

        // Real audio for chunk 2.
        XCTAssertEqual(FarewellAdvancer.handle(.audioDelta, state: state), .markAudioStarted)
        state.chunkAudioStarted = true

        // Audio for chunk 2 finishes. Advance to chunk 3.
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .sendNextChunk)
        state.chainIndex = 3
        state.chunkAudioStarted = false

        // Real audio for chunk 3.
        XCTAssertEqual(FarewellAdvancer.handle(.audioDelta, state: state), .markAudioStarted)
        state.chunkAudioStarted = true

        // Audio for chunk 3 finishes. Chain drained → arm auto-end.
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .armSilenceAutoEnd)
    }

    // MARK: - End-to-end — 4.log failure mode (missing audioDone)

    /// Replays the exact `debug-f3b222 4.log` scenario: all three
    /// chunks get early done events that are ignored, and no real
    /// `responseAudioDone` arrives for chunk 3. The per-chunk timeout
    /// must fire and force `armSilenceAutoEnd` so the farewell
    /// completes instead of hanging.
    func test_threeChunkFarewell_missingAudioDone_timeoutRecovers() {
        var state = FarewellState(chainIndex: 1, chainCount: 3, chunkAudioStarted: false)

        // Chunk 1: early done (ignored), audio arrives, real done.
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .ignoreEarlyDone)
        XCTAssertEqual(FarewellAdvancer.handle(.audioDelta, state: state), .markAudioStarted)
        state.chunkAudioStarted = true
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .sendNextChunk)
        state.chainIndex = 2
        state.chunkAudioStarted = false

        // Chunk 2: early done (ignored), audio arrives, real done.
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .ignoreEarlyDone)
        XCTAssertEqual(FarewellAdvancer.handle(.audioDelta, state: state), .markAudioStarted)
        state.chunkAudioStarted = true
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .sendNextChunk)
        state.chainIndex = 3
        state.chunkAudioStarted = false

        // Chunk 3: early done (ignored). Audio arrives but real done
        // NEVER comes. Per-chunk timeout fires → must arm auto-end.
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .ignoreEarlyDone)
        XCTAssertEqual(FarewellAdvancer.handle(.audioDelta, state: state), .markAudioStarted)
        state.chunkAudioStarted = true
        // No real audioDone — timeout fires instead.
        XCTAssertEqual(FarewellAdvancer.handle(.chunkTimeout, state: state), .armSilenceAutoEnd)
    }

    // MARK: - 5.log regression: chain completes but late audioDone arrives

    /// In `debug-f3b222 5.log`, the farewell chain completed successfully
    /// (all 3 chunks sent, audio played, armSilenceAutoEnd fired). But
    /// after armSilenceAutoEnd reset `chunkAudioStarted = false`, a LATE
    /// `responseAudioDone` arrived. The advancer must return
    /// `.ignoreEarlyDone` for this straggler (since chunkAudioStarted is
    /// false), not erroneously re-arm the silence timer or send more
    /// chunks.
    func test_lateAudioDoneAfterChainComplete_isIgnored() {
        // Chain fully drained: chainIndex=3, chainCount=3.
        // After armSilenceAutoEnd the coordinator resets chunkAudioStarted.
        let state = FarewellState(chainIndex: 3, chainCount: 3, chunkAudioStarted: false)
        XCTAssertEqual(FarewellAdvancer.handle(.audioDone, state: state), .ignoreEarlyDone)
    }
}
