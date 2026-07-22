import Foundation

/// Pure decision logic for advancing the no-rounds-left farewell chain.
///
/// The chain is a sequence of short `responseCreate` instructions
/// (summary → purchase CTA → goodbye). Each chunk is sent as its own
/// AI turn. The challenge is timing: Gemini sometimes emits
/// `responseAudioDone` BEFORE actual audio starts streaming for the
/// chunk we just sent. If we naively advance on the first
/// `responseAudioDone` we receive, we step on the previous chunk
/// (regression in `mic_gating 8.log` — purchase CTA was overrun by
/// the goodbye chunk).
///
/// The fix is to gate advancement on `farewellChunkAudioStarted`:
/// only advance once we've seen a real audio delta for the current
/// chunk. The coordinator owns the flag; this advancer answers
/// "given the current state and an event, what should happen?"
///
/// A second failure mode was discovered in `debug-f3b222 4.log`
/// (2026-05-07): Gemini never sends `responseAudioDone` for the last
/// chunk. Every early done gets ignored, the chain stalls, and the
/// 45 s fallback timer or a server-side WS close eventually tears
/// down the session — cutting off the farewell mid-speech. The fix
/// is a per-chunk timeout event (`.chunkTimeout`): if N seconds pass
/// without a real `responseAudioDone`, the advancer treats it the
/// same as a real done — advance to the next chunk or arm auto-end.

public enum FarewellEvent: Equatable {
    /// AI began streaming audio for the current chunk.
    case audioDelta
    /// AI signalled the end of a turn.
    case audioDone
    /// Per-chunk timer fired — Gemini never sent `responseAudioDone`
    /// for this chunk within the allowed window.
    case chunkTimeout
}

public struct FarewellState: Equatable {
    public var chainIndex: Int
    public var chainCount: Int
    public var chunkAudioStarted: Bool

    public init(
        chainIndex: Int,
        chainCount: Int,
        chunkAudioStarted: Bool
    ) {
        self.chainIndex = chainIndex
        self.chainCount = chainCount
        self.chunkAudioStarted = chunkAudioStarted
    }

    public var isChainComplete: Bool { chainIndex >= chainCount }
}

public enum FarewellAction: Equatable {
    /// AI started streaming. Mark the current chunk as having
    /// produced real audio. Caller should set
    /// `chunkAudioStarted = true` and cancel any silence-end timer.
    case markAudioStarted

    /// Premature `responseAudioDone` (no audio for this chunk yet).
    /// Ignore it — wait for the real one.
    case ignoreEarlyDone

    /// Real `responseAudioDone` after audio. Advance to the next
    /// chunk. Caller should reset `chunkAudioStarted = false` and
    /// schedule `sendNextFarewellChunk`.
    case sendNextChunk

    /// Chain drained. Arm the silence-based auto-end so the session
    /// ends shortly.
    case armSilenceAutoEnd
}

public enum FarewellAdvancer {

    /// Decide what should happen given an event and current state.
    public static func handle(_ event: FarewellEvent, state: FarewellState) -> FarewellAction {
        switch event {
        case .audioDelta:
            return .markAudioStarted

        case .audioDone:
            guard state.chunkAudioStarted else {
                return .ignoreEarlyDone
            }
            return advanceOrEnd(state: state)

        case .chunkTimeout:
            // Timeout means Gemini never sent `responseAudioDone` (or
            // we only got early ones). If we received at least some
            // audio, the chunk DID play — advance normally. If we got
            // NO audio at all, the chunk was a no-op — still advance
            // so we don't stall the entire farewell chain.
            return advanceOrEnd(state: state)
        }
    }

    private static func advanceOrEnd(state: FarewellState) -> FarewellAction {
        if state.chainIndex < state.chainCount {
            return .sendNextChunk
        } else {
            return .armSilenceAutoEnd
        }
    }
}
