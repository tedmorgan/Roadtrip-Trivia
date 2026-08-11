import XCTest
@testable import RoadtripTriviaRealtime

final class RealtimeModelsTests: XCTestCase {

    func test_forceMessage_jsonShape_isVerbatimTTSTurn() throws {
        let json = try XCTUnwrap(
            RealtimeClientEvent.forceMessage(
                text: "Thanks for playing Roadtrip Trivia! Come back soon.",
                interruptible: false
            ).toJSON()
        )

        XCTAssertEqual(json["type"] as? String, "conversation.item.create")
        let item = try XCTUnwrap(json["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "force_message")
        XCTAssertEqual(item["role"] as? String, "assistant")
        XCTAssertEqual(item["interruptible"] as? Bool, false)
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "output_text")
        XCTAssertEqual(
            content.first?["text"] as? String,
            "Thanks for playing Roadtrip Trivia! Come back soon."
        )
    }

    func test_transcriptionKeyterms_nestedUnderSessionAudioInput() throws {
        let terms = ["Paris", "A", "Geography"]
        let json = try XCTUnwrap(
            RealtimeClientEvent.transcriptionKeyterms(terms).toJSON()
        )

        XCTAssertEqual(json["type"] as? String, "session.update")
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "grok-transcribe")
        XCTAssertEqual(transcription["keyterms"] as? [String], terms)
    }

    func test_sessionUpdate_usesGrokVoiceDefaults() throws {
        let config = SessionConfig(
            instructions: "Host the game.",
            voice: "sal",
            tools: [
                RealtimeTool(
                    name: "get_next_question",
                    description: "Get next question",
                    parameters: ["type": "object", "properties": [:] as [String: Any]]
                )
            ]
        )
        let json = try XCTUnwrap(RealtimeClientEvent.sessionUpdate(config).toJSON())
        XCTAssertEqual(json["type"] as? String, "session.update")
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        XCTAssertEqual(session["voice"] as? String, "sal")
        let reasoning = try XCTUnwrap(session["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "none")
        let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        XCTAssertEqual(tools.first?["name"] as? String, "get_next_question")
        XCTAssertEqual(config.model, "grok-voice-think-fast-2.0")
    }

    func test_responseCancel_isNativeCancelEvent() throws {
        let json = try XCTUnwrap(RealtimeClientEvent.responseCancel.toJSON())
        XCTAssertEqual(json["type"] as? String, "response.cancel")
    }

    func test_parse_functionCallArgumentsDone() throws {
        let payload: [String: Any] = [
            "type": "response.function_call_arguments.done",
            "call_id": "call_1",
            "name": "report_score",
            "arguments": #"{"playerAnswer":"A","isCorrect":true}"#
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let events = RealtimeServerEvent.parse(from: data)
        guard case .responseFunctionCallArgumentsDone(let callId, let name, let args)? = events.first else {
            return XCTFail("expected function call event")
        }
        XCTAssertEqual(callId, "call_1")
        XCTAssertEqual(name, "report_score")
        XCTAssertTrue(args.contains("playerAnswer"))
    }

    func test_parse_conversationCreated_asResumptionToken() throws {
        let payload: [String: Any] = [
            "type": "conversation.created",
            "conversation": ["id": "conv_abc123"]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let events = RealtimeServerEvent.parse(from: data)
        guard case .sessionResumptionUpdate(let token)? = events.first else {
            return XCTFail("expected resumption update")
        }
        XCTAssertEqual(token, "conv_abc123")
    }

    func test_parse_audioDeltaAndDone() throws {
        let delta: [String: Any] = [
            "type": "response.output_audio.delta",
            "response_id": "resp_1",
            "delta": "AAAA"
        ]
        let done: [String: Any] = [
            "type": "response.output_audio.done",
            "response_id": "resp_1"
        ]
        let deltaEvents = RealtimeServerEvent.parse(from: try JSONSerialization.data(withJSONObject: delta))
        let doneEvents = RealtimeServerEvent.parse(from: try JSONSerialization.data(withJSONObject: done))
        guard case .responseAudioDelta(let responseId, let audio)? = deltaEvents.first else {
            return XCTFail("expected audio delta")
        }
        XCTAssertEqual(responseId, "resp_1")
        XCTAssertEqual(audio, "AAAA")
        guard case .responseAudioDone(let doneId)? = doneEvents.first else {
            return XCTFail("expected audio done")
        }
        XCTAssertEqual(doneId, "resp_1")
    }

    func test_parse_responseDone_withUsage() throws {
        let payload: [String: Any] = [
            "type": "response.done",
            "response": [
                "usage": [
                    "input_tokens": 120,
                    "output_tokens": 40,
                    "total_tokens": 160
                ]
            ]
        ]
        let events = RealtimeServerEvent.parse(from: try JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(events.count, 2)
        guard case .usageMetadata(let prompt, let response, let total, _)? = events.first else {
            return XCTFail("expected usage metadata")
        }
        XCTAssertEqual(prompt, 120)
        XCTAssertEqual(response, 40)
        XCTAssertEqual(total, 160)
        guard case .responseDone = events.last else {
            return XCTFail("expected responseDone")
        }
    }
}
