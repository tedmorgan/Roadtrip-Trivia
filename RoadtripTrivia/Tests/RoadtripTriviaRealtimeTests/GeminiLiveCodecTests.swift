import XCTest
@testable import RoadtripTriviaRealtime

final class GeminiLiveCodecTests: XCTestCase {
    private func config() -> SessionConfig {
        SessionConfig(
            instructions: "Host the game. [APP_CONTROL] is app-owned.",
            voice: "Puck",
            tools: [
                RealtimeTool(
                    name: "get_next_question",
                    description: "Get the next question.",
                    parameters: [
                        "type": "object",
                        "properties": [:] as [String: Any],
                    ]
                ),
            ],
            model: "gemini-3.1-flash-live-preview",
            resumptionHandle: "resume-123"
        )
    }

    func test_setupUsesAudioVoiceBlockingToolsResumptionAndCompression() throws {
        let setup = try XCTUnwrap(
            GeminiLiveCodec().setupMessage(config: config())["setup"] as? [String: Any]
        )
        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.1-flash-live-preview")

        let generation = try XCTUnwrap(setup["generationConfig"] as? [String: Any])
        XCTAssertEqual(generation["responseModalities"] as? [String], ["AUDIO"])
        let speech = try XCTUnwrap(generation["speechConfig"] as? [String: Any])
        let voiceConfig = try XCTUnwrap(speech["voiceConfig"] as? [String: Any])
        let prebuilt = try XCTUnwrap(voiceConfig["prebuiltVoiceConfig"] as? [String: Any])
        XCTAssertEqual(prebuilt["voiceName"] as? String, "Puck")

        let tools = try XCTUnwrap(setup["tools"] as? [[String: Any]])
        let declarations = try XCTUnwrap(
            tools.first?["functionDeclarations"] as? [[String: Any]]
        )
        XCTAssertEqual(declarations.first?["behavior"] as? String, "BLOCKING")
        let parameters = try XCTUnwrap(declarations.first?["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "OBJECT")

        let resumption = try XCTUnwrap(setup["sessionResumption"] as? [String: Any])
        XCTAssertEqual(resumption["handle"] as? String, "resume-123")
        let compression = try XCTUnwrap(
            setup["contextWindowCompression"] as? [String: Any]
        )
        XCTAssertEqual(compression["triggerTokens"] as? Int, 25_000)
        let window = try XCTUnwrap(compression["slidingWindow"] as? [String: Any])
        XCTAssertEqual(window["targetTokens"] as? Int, 8_000)
        let realtimeInput = try XCTUnwrap(setup["realtimeInputConfig"] as? [String: Any])
        XCTAssertEqual(realtimeInput["activityHandling"] as? String, "NO_INTERRUPTION")
    }

    func test_audioAndControlMessagesUseGeminiEnvelopes() throws {
        let audio = GeminiLiveCodec.audioMessage(base64Audio: "AAAA")
        let realtime = try XCTUnwrap(audio["realtimeInput"] as? [String: Any])
        let blob = try XCTUnwrap(realtime["audio"] as? [String: Any])
        XCTAssertEqual(blob["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(blob["data"] as? String, "AAAA")

        let control = GeminiLiveCodec.controlMessage(
            instructions: "Call get_next_question now."
        )
        let client = try XCTUnwrap(control["clientContent"] as? [String: Any])
        XCTAssertEqual(client["turnComplete"] as? Bool, true)
        let turns = try XCTUnwrap(client["turns"] as? [[String: Any]])
        let parts = try XCTUnwrap(turns.first?["parts"] as? [[String: Any]])
        XCTAssertTrue(parts.first?["text"] as? String ~= "[APP_CONTROL]")
    }

    func test_parseSetupAudioTranscriptsAndTurnCompletion() throws {
        let codec = GeminiLiveCodec()
        let setupEvents = codec.parse(try data(["setupComplete": [:]]))
        XCTAssertEqual(setupEvents.count, 2)
        guard case .sessionUpdated = setupEvents.last else {
            return XCTFail("expected setup acknowledgement")
        }

        let payload: [String: Any] = [
            "serverContent": [
                "modelTurn": [
                    "parts": [[
                        "inlineData": [
                            "mimeType": "audio/pcm;rate=24000",
                            "data": "BBBB",
                        ],
                    ]],
                ],
                "inputTranscription": ["text": "team road"],
                "outputTranscription": ["text": "Welcome!"],
                "generationComplete": true,
            ],
        ]
        let events = codec.parse(try data(payload))
        XCTAssertTrue(events.containsAudio("BBBB"))
        XCTAssertTrue(events.containsInputTranscript("team road"))
        XCTAssertTrue(events.containsOutputTranscript("Welcome!"))
        XCTAssertEqual(events.audioDoneCount, 1)

        let completed = codec.parse(try data([
            "serverContent": ["turnComplete": true],
        ]))
        XCTAssertEqual(completed.audioDoneCount, 0)
        guard case .responseDone = completed.last else {
            return XCTFail("expected one turn completion")
        }
    }

    func test_parseToolsCancellationResumptionGoAwayAndUsage() throws {
        let codec = GeminiLiveCodec()
        let toolEvents = codec.parse(try data([
            "toolCall": [
                "functionCalls": [[
                    "id": "call-1",
                    "name": "report_score",
                    "args": ["playerAnswer": "A", "isCorrect": true],
                ]],
            ],
        ]))
        guard case .responseFunctionCallArgumentsDone(
            let id, let name, let arguments
        )? = toolEvents.first else {
            return XCTFail("expected function call")
        }
        XCTAssertEqual(id, "call-1")
        XCTAssertEqual(name, "report_score")
        XCTAssertTrue(arguments.contains("playerAnswer"))

        let cancellation = codec.parse(try data([
            "toolCallCancellation": ["ids": ["call-1"]],
        ]))
        guard case .error(_, let code)? = cancellation.first else {
            return XCTFail("expected cancellation")
        }
        XCTAssertEqual(code, "tool_call_cancelled")

        let resumption = codec.parse(try data([
            "sessionResumptionUpdate": [
                "resumable": true,
                "newHandle": "handle-2",
            ],
        ]))
        guard case .sessionResumptionUpdate(let handle)? = resumption.first else {
            return XCTFail("expected resumption handle")
        }
        XCTAssertEqual(handle, "handle-2")

        let goAway = codec.parse(try data([
            "goAway": ["timeLeft": "5s"],
        ]))
        guard case .error(_, let goAwayCode)? = goAway.first else {
            return XCTFail("expected GoAway")
        }
        XCTAssertEqual(goAwayCode, "go_away")

        let usage = codec.parse(try data([
            "usageMetadata": [
                "promptTokenCount": 100,
                "responseTokenCount": 20,
                "thoughtsTokenCount": 4,
                "totalTokenCount": 124,
            ],
        ]))
        guard case .usageMetadata(let prompt, let response, let total, let raw)?
            = usage.first else {
            return XCTFail("expected usage metadata")
        }
        XCTAssertEqual(prompt, 100)
        XCTAssertEqual(response, 20)
        XCTAssertEqual(total, 124)
        XCTAssertEqual(raw["thoughtsTokenCount"] as? Int, 4)
    }

    func test_toolTurnStateWaitsForAllParallelResultsAndDeduplicates() {
        var state = GeminiToolTurnState()
        XCTAssertTrue(state.registerCall(id: "call-1"))
        XCTAssertTrue(state.registerCall(id: "call-2"))
        XCTAssertFalse(state.registerCall(id: "call-1"))

        XCTAssertTrue(state.queueResponse(
            GeminiFunctionResponse(
                id: "call-1",
                name: "get_location",
                result: ["location": "Boston"]
            )
        ))
        XCTAssertNil(state.drainResponses(appControl: nil))

        XCTAssertTrue(state.queueResponse(
            GeminiFunctionResponse(
                id: "call-2",
                name: "get_next_question",
                result: ["questionText": "Question?"]
            )
        ))
        XCTAssertFalse(state.queueResponse(
            GeminiFunctionResponse(
                id: "call-2",
                name: "get_next_question",
                result: [:]
            )
        ))

        let responses = state.drainResponses(appControl: "TIME IS UP")
        XCTAssertEqual(responses?.count, 2)
        XCTAssertEqual(responses?.first?.result["appControl"] as? String, "TIME IS UP")
        XCTAssertFalse(state.hasPendingResponses)
    }

    private func data(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json)
    }
}

private extension Array where Element == RealtimeServerEvent {
    func containsAudio(_ expected: String) -> Bool {
        contains {
            if case .responseAudioDelta(_, let audio) = $0 {
                return audio == expected
            }
            return false
        }
    }

    func containsInputTranscript(_ expected: String) -> Bool {
        contains {
            if case .responseAudioTranscriptDelta(let text) = $0 {
                return text == expected
            }
            return false
        }
    }

    func containsOutputTranscript(_ expected: String) -> Bool {
        contains {
            if case .responseAudioTranscriptDone(let text) = $0 {
                return text == expected
            }
            return false
        }
    }

    var audioDoneCount: Int {
        reduce(0) { count, event in
            if case .responseAudioDone = event { return count + 1 }
            return count
        }
    }
}

private func ~= (lhs: String?, rhs: String) -> Bool {
    lhs?.contains(rhs) == true
}
