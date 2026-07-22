import XCTest
@testable import RoadtripTriviaLogic

/// Regression fixtures for "user answers immediately and isn't heard"
/// (reported in the very first bug list: the host pauses when the player
/// responds right after the question, because the gated mic dropped the
/// first words of the answer).
final class PreRollBufferTests: XCTestCase {

    func test_earlyAnswerTailIsPreserved() {
        // Host audio drains; player starts answering ~300ms before unmute.
        var buf = PreRollBuffer(maxChunks: 6)
        buf.append(base64Audio: "silence1", hasVoice: false)
        buf.append(base64Audio: "silence2", hasVoice: false)
        buf.append(base64Audio: "voice1", hasVoice: true)   // "B..."
        buf.append(base64Audio: "voice2", hasVoice: true)   // "...the Amazon"
        let flushed = buf.drainForFlush()
        XCTAssertEqual(flushed, ["voice1", "voice2"],
                       "voice tail is flushed, leading silence is dropped")
        XCTAssertTrue(buf.chunks.isEmpty, "drain clears the buffer")
    }

    func test_pureNoiseIsNeverFlushed() {
        // Echo guard: host speech picked up by the mic must not be replayed
        // to the server as user input — that's how false VAD storms start.
        var buf = PreRollBuffer(maxChunks: 6)
        for i in 0..<6 {
            buf.append(base64Audio: "noise\(i)", hasVoice: false)
        }
        XCTAssertEqual(buf.drainForFlush(), [],
                       "no voice captured → nothing flushed")
    }

    func test_bufferIsCappedToTail() {
        // Only the recent tail survives — we never replay seconds of audio.
        var buf = PreRollBuffer(maxChunks: 3)
        for i in 0..<10 {
            buf.append(base64Audio: "c\(i)", hasVoice: true)
        }
        XCTAssertEqual(buf.chunks.count, 3)
        XCTAssertEqual(buf.drainForFlush(), ["c7", "c8", "c9"])
    }

    func test_voiceInterleavedWithSilenceKeepsFromFirstVoice() {
        var buf = PreRollBuffer(maxChunks: 6)
        buf.append(base64Audio: "s1", hasVoice: false)
        buf.append(base64Audio: "v1", hasVoice: true)
        buf.append(base64Audio: "s2", hasVoice: false) // brief intra-word gap
        buf.append(base64Audio: "v2", hasVoice: true)
        XCTAssertEqual(buf.drainForFlush(), ["v1", "s2", "v2"],
                       "intra-speech gaps are kept so the utterance isn't chopped")
    }

    func test_clearEmptiesWithoutFlushing() {
        var buf = PreRollBuffer(maxChunks: 6)
        buf.append(base64Audio: "v1", hasVoice: true)
        buf.clear()
        XCTAssertEqual(buf.drainForFlush(), [])
    }
}
