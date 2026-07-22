import Foundation

/// Rolling buffer of recent mic audio chunks captured WHILE the mic is gated.
///
/// Why this exists: the mic unmutes only ~150ms after the host's playback
/// drains. A player who answers the instant the host finishes loses the first
/// word(s) of their answer — the server VAD never opens a turn and the game
/// sits in dead air ("the app does not appear to hear it and just pauses",
/// reported in the very first bug list and never fully fixed since).
///
/// While gated, converted 16kHz chunks are appended here instead of being
/// dropped. On unmute the recent voice-bearing tail is flushed to the server
/// ahead of live audio, so the start of an early answer is preserved.
///
/// Echo guard: the buffer intentionally keeps only a short tail
/// (`maxChunks` ≈ 600ms) and drops leading non-voice chunks at flush time,
/// so we never replay seconds of the host's own speech (speaker echo)
/// back into the model as user input.
struct PreRollBuffer {

    struct Chunk: Equatable {
        let base64Audio: String
        let hasVoice: Bool
    }

    /// ~600ms at 100ms per chunk.
    let maxChunks: Int

    private(set) var chunks: [Chunk] = []

    init(maxChunks: Int = 6) {
        self.maxChunks = maxChunks
    }

    mutating func append(base64Audio: String, hasVoice: Bool) {
        chunks.append(Chunk(base64Audio: base64Audio, hasVoice: hasVoice))
        if chunks.count > maxChunks {
            chunks.removeFirst(chunks.count - maxChunks)
        }
    }

    /// Returns the chunks worth sending on unmute: everything from the first
    /// voice-bearing chunk onward (leading silence/noise is dropped). Returns
    /// an empty array when no voice was captured — flushing pure noise would
    /// feed echo back to the server VAD.
    /// Always clears the buffer.
    mutating func drainForFlush() -> [String] {
        defer { chunks.removeAll() }
        guard let firstVoice = chunks.firstIndex(where: { $0.hasVoice }) else {
            return []
        }
        return chunks[firstVoice...].map { $0.base64Audio }
    }

    mutating func clear() {
        chunks.removeAll()
    }
}
