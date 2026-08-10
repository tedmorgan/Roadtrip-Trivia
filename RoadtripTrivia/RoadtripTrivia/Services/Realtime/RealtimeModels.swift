import Foundation

// MARK: - Client → Server Events (xAI Realtime API)

/// Wrapper for events sent to Grok Voice over xAI's OpenAI-compatible
/// Realtime WebSocket API.
enum RealtimeClientEvent {

    /// Configure the voice session after the WebSocket opens.
    case sessionUpdate(SessionConfig)

    /// Append a chunk of base64-encoded PCM16 audio from the microphone.
    case inputAudioBufferAppend(audio: String)

    /// Clear the audio buffer (unused in practice).
    case inputAudioBufferClear

    /// Ask Grok to generate the next response, optionally with one-turn
    /// instructions. `response.create` itself is not a billable text event.
    case responseCreate(instructions: String?)

    /// Provide the result of a function call back to the model.
    case conversationItemCreate(callId: String, name: String, output: String)

    /// Speak a verbatim TTS line without involving the model (xAI extension).
    /// Do not follow with `response.create` — this item IS the turn.
    case forceMessage(text: String, interruptible: Bool)

    /// Mid-session ASR bias for the current question's answer vocabulary.
    case transcriptionKeyterms([String])

    /// Interrupt the model's current generation.
    case responseCancel

    func toJSON() -> [String: Any]? {
        switch self {
        case .sessionUpdate(let config):
            var session: [String: Any] = [
                "instructions": config.instructions,
                "voice": config.voice,
                // High road-noise threshold plus the existing local RMS
                // corroboration prevents false cabin-noise barge-ins.
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.85,
                    "silence_duration_ms": 800,
                    "prefix_padding_ms": 333
                ] as [String: Any],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 16000],
                        "transport": "json",
                        "transcription": ["model": "grok-transcribe"]
                    ] as [String: Any],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "transport": "json"
                    ] as [String: Any]
                ] as [String: Any],
                // Think Fast's high reasoning default is unnecessary for the
                // app-owned game state and adds perceptible voice latency.
                "reasoning": ["effort": "none"],
                "resumption": ["enabled": true]
            ]
            if !config.tools.isEmpty {
                session["tools"] = config.tools.map { $0.toDictionary() }
            }
            return ["type": "session.update", "session": session]

        case .inputAudioBufferAppend(let audio):
            return ["type": "input_audio_buffer.append", "audio": audio]

        case .inputAudioBufferClear:
            return ["type": "input_audio_buffer.clear"]

        case .responseCreate(let instructions):
            var event: [String: Any] = ["type": "response.create"]
            if let instructions, !instructions.isEmpty {
                event["response"] = ["instructions": instructions]
            }
            return event

        case .conversationItemCreate(let callId, _, let output):
            return [
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": output
                ] as [String: Any]
            ]

        case .forceMessage(let text, let interruptible):
            return [
                "type": "conversation.item.create",
                "item": [
                    "type": "force_message",
                    "role": "assistant",
                    "interruptible": interruptible,
                    "content": [
                        ["type": "output_text", "text": text]
                    ]
                ] as [String: Any]
            ]

        case .transcriptionKeyterms(let terms):
            return [
                "type": "session.update",
                "session": [
                    "audio": [
                        "input": [
                            "transcription": [
                                "model": "grok-transcribe",
                                "keyterms": terms
                            ] as [String: Any]
                        ] as [String: Any]
                    ] as [String: Any]
                ] as [String: Any]
            ]

        case .responseCancel:
            return ["type": "response.cancel"]
        }
    }

    func toData() throws -> Data {
        guard let json = toJSON() else {
            return Data()
        }
        return try JSONSerialization.data(withJSONObject: json)
    }
}

// MARK: - Session Configuration

struct SessionConfig {
    let instructions: String
    let voice: String
    let tools: [RealtimeTool]
    let model: String
    /// xAI conversation ID used to restore server-side history on reconnect.
    var resumptionHandle: String?

    init(instructions: String, voice: String, tools: [RealtimeTool], model: String = "grok-voice-think-fast-2.0", resumptionHandle: String? = nil) {
        self.instructions = instructions
        self.voice = voice
        self.tools = tools
        self.model = model
        self.resumptionHandle = resumptionHandle
    }
}

struct RealtimeTool {
    let name: String
    let description: String
    let parameters: [String: Any]

    /// xAI/OpenAI Realtime function tool format.
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": "function",
            "name": name,
            "description": description,
        ]
        if !parameters.isEmpty {
            dict["parameters"] = parameters
        }
        return dict
    }
}

// MARK: - Server → Client Events (xAI Realtime API)

/// Provider-neutral events consumed by the coordinator and audio service.
enum RealtimeServerEvent {
    case sessionCreated(sessionId: String)
    case sessionUpdated
    case responseAudioDelta(responseId: String, audio: String)
    case responseAudioDone(responseId: String)
    case responseAudioTranscriptDelta(text: String)
    case responseAudioTranscriptDone(text: String)
    case responseFunctionCallArgumentsDone(callId: String, name: String, arguments: String)
    case responseDone
    case inputAudioBufferSpeechStarted
    case inputAudioBufferSpeechStopped
    case inputAudioBufferCommitted
    case sessionResumptionUpdate(token: String)
    case usageMetadata(promptTokens: Int, responseTokens: Int, totalTokens: Int, raw: [String: Any])
    case error(message: String, code: String?)
    case unknown(type: String)

    /// Parse an xAI Realtime server event into the app's existing event model.
    static func parse(from data: Data) -> [RealtimeServerEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let type = json["type"] as? String ?? "unknown"
        switch type {
        case "session.created":
            let session = json["session"] as? [String: Any]
            return [.sessionCreated(sessionId: session?["id"] as? String ?? "grok")]

        case "session.updated":
            return [.sessionUpdated]

        case "conversation.created":
            let conversation = json["conversation"] as? [String: Any]
            guard let id = conversation?["id"] as? String else {
                return [.unknown(type: type)]
            }
            return [.sessionResumptionUpdate(token: id)]

        case "response.output_audio.delta", "response.audio.delta":
            let responseId = json["response_id"] as? String ?? "grok"
            guard let audio = json["delta"] as? String ?? json["audio"] as? String else {
                return [.unknown(type: type)]
            }
            return [.responseAudioDelta(responseId: responseId, audio: audio)]

        case "response.output_audio.done", "response.audio.done":
            return [.responseAudioDone(responseId: json["response_id"] as? String ?? "grok")]

        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            return [.responseAudioTranscriptDone(text: json["delta"] as? String ?? "")]

        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            return [.responseAudioTranscriptDone(text: json["transcript"] as? String ?? "")]

        case "conversation.item.input_audio_transcription.updated":
            let text = json["transcript"] as? String ?? json["text"] as? String ?? ""
            return text.isEmpty ? [] : [.responseAudioTranscriptDelta(text: text)]

        case "conversation.item.input_audio_transcription.completed":
            let text = json["transcript"] as? String ?? ""
            return text.isEmpty ? [] : [.responseAudioTranscriptDelta(text: text)]

        case "response.function_call_arguments.done":
            return [.responseFunctionCallArgumentsDone(
                callId: json["call_id"] as? String ?? UUID().uuidString,
                name: json["name"] as? String ?? "",
                arguments: json["arguments"] as? String ?? "{}"
            )]

        case "response.done":
            var events: [RealtimeServerEvent] = []
            if let response = json["response"] as? [String: Any],
               let usage = response["usage"] as? [String: Any] {
                let parsed = ResponseUsage.from(usageDictionary: usage)
                events.append(.usageMetadata(
                    promptTokens: parsed.inputTokens,
                    responseTokens: parsed.outputTokens,
                    totalTokens: parsed.totalTokens,
                    raw: usage
                ))
            }
            events.append(.responseDone)
            return events

        case "input_audio_buffer.speech_started":
            return [.inputAudioBufferSpeechStarted]

        case "input_audio_buffer.speech_stopped":
            return [.inputAudioBufferSpeechStopped]

        case "input_audio_buffer.committed":
            return [.inputAudioBufferCommitted]

        case "response.cancelled":
            return [.error(message: "Response cancelled", code: "response_cancelled")]

        case "error":
            let error = json["error"] as? [String: Any]
            return [.error(
                message: error?["message"] as? String ?? "Unknown xAI Realtime error",
                code: error?["code"] as? String ?? error?["type"] as? String
            )]

        default:
            return [.unknown(type: type)]
        }
    }

    /// Legacy single-event parser for backward compatibility where needed.
    static func parseFirst(from data: Data) -> RealtimeServerEvent? {
        let events: [RealtimeServerEvent] = parse(from: data)
        return events.first
    }
}

// MARK: - Function Call Argument Parsing

struct SetGameConfigArgs: Codable {
    let playerCount: Int
    let teamName: String?
    let difficulty: String
    let ageBands: [String]
}

struct ReportScoreArgs: Codable {
    let questionIndex: Int
    let questionText: String?
    let playerAnswer: String?
    let isCorrect: Bool
    let wasChallenge: Bool?
    let wasHint: Bool?
    let roundNumber: Int?
    let category: String?
    let isLightning: Bool?
}

struct EndGameArgs: Codable {
    let finalScore: Int
    let totalQuestions: Int
}

// MARK: - Token Response

struct GrokTokenResponse: Codable {
    let value: String
    let expiresAt: Int
    let model: String

    enum CodingKeys: String, CodingKey {
        case value
        case expiresAt = "expires_at"
        case model
    }
}

/// Still used by the Gemini REST question-batch service. Live voice no longer
/// consumes this long-lived key.
struct GeminiTokenResponse: Codable {
    let apiKey: String
    let model: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model
    }
}
