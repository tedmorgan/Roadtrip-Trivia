import Foundation

// MARK: - Client → Server Events

/// Wrapper for all events sent to the Realtime API over WebSocket.
enum RealtimeClientEvent {

    /// Update session configuration (system prompt, tools, voice, turn detection).
    case sessionUpdate(SessionConfig)

    /// Append a chunk of base64-encoded PCM16 audio from the microphone.
    case inputAudioBufferAppend(audio: String)

    /// Commit the current audio buffer (signals end of user speech when using manual VAD).
    case inputAudioBufferClear

    /// Request the model to generate a response.
    case responseCreate(instructions: String?)

    /// Provide the result of a function call back to the model.
    case conversationItemCreate(callId: String, output: String)

    /// Cancel an in-progress response (e.g., user interrupted).
    case responseCancel

    func toJSON() -> [String: Any] {
        switch self {
        case .sessionUpdate(let config):
            var session: [String: Any] = [
                "modalities": ["text", "audio"],
                "instructions": config.instructions,
                "voice": config.voice,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 800
                ] as [String: Any]
            ]
            if !config.tools.isEmpty {
                session["tools"] = config.tools.map { $0.toDictionary() }
                session["tool_choice"] = "auto"
            }
            return ["type": "session.update", "session": session]

        case .inputAudioBufferAppend(let audio):
            return ["type": "input_audio_buffer.append", "audio": audio]

        case .inputAudioBufferClear:
            return ["type": "input_audio_buffer.clear"]

        case .responseCreate(let instructions):
            var response: [String: Any] = ["modalities": ["text", "audio"]]
            if let instructions {
                response["instructions"] = instructions
            }
            return ["type": "response.create", "response": response]

        case .conversationItemCreate(let callId, let output):
            return [
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": output
                ] as [String: Any]
            ]

        case .responseCancel:
            return ["type": "response.cancel"]
        }
    }

    func toData() throws -> Data {
        try JSONSerialization.data(withJSONObject: toJSON())
    }
}

// MARK: - Session Configuration

struct SessionConfig {
    let instructions: String
    let voice: String
    let tools: [RealtimeTool]
}

struct RealtimeTool {
    let name: String
    let description: String
    let parameters: [String: Any]

    func toDictionary() -> [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "parameters": parameters
        ]
    }
}

// MARK: - Server → Client Events

/// Parsed event received from the Realtime API.
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
    case error(message: String, code: String?)
    case unknown(type: String)

    static func parse(from data: Data) -> RealtimeServerEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "session.created":
            let sessionId = (json["session"] as? [String: Any])?["id"] as? String ?? ""
            return .sessionCreated(sessionId: sessionId)

        case "session.updated":
            return .sessionUpdated

        case "response.audio.delta":
            let responseId = json["response_id"] as? String ?? ""
            let audio = json["delta"] as? String ?? ""
            return .responseAudioDelta(responseId: responseId, audio: audio)

        case "response.audio.done":
            let responseId = json["response_id"] as? String ?? ""
            return .responseAudioDone(responseId: responseId)

        case "response.audio_transcript.delta":
            let delta = json["delta"] as? String ?? ""
            return .responseAudioTranscriptDelta(text: delta)

        case "response.audio_transcript.done":
            let transcript = json["transcript"] as? String ?? ""
            return .responseAudioTranscriptDone(text: transcript)

        case "response.function_call_arguments.done":
            let callId = json["call_id"] as? String ?? ""
            let name = json["name"] as? String ?? ""
            let arguments = json["arguments"] as? String ?? "{}"
            return .responseFunctionCallArgumentsDone(callId: callId, name: name, arguments: arguments)

        case "response.done":
            return .responseDone

        case "input_audio_buffer.speech_started":
            return .inputAudioBufferSpeechStarted

        case "input_audio_buffer.speech_stopped":
            return .inputAudioBufferSpeechStopped

        case "input_audio_buffer.committed":
            return .inputAudioBufferCommitted

        case "error":
            let errorInfo = json["error"] as? [String: Any]
            let message = errorInfo?["message"] as? String ?? "Unknown error"
            let code = errorInfo?["code"] as? String
            return .error(message: message, code: code)

        default:
            return .unknown(type: type)
        }
    }
}

// MARK: - Function Call Argument Parsing

/// Parsed arguments from LLM function calls.
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
}

struct UpdateUIArgs: Codable {
    let state: String
    let label: String?
}

struct CheckpointGameArgs: Codable {
    let roundNumber: Int
    let questionIndex: Int
    let category: String?
    let totalCorrect: Int
    let totalAnswered: Int
}

struct EndGameArgs: Codable {
    let finalScore: Int
    let totalQuestions: Int
}

// MARK: - Token Response

struct EphemeralTokenResponse: Codable {
    let clientSecret: String
    let expiresAt: Double?
    let sessionId: String?
    let voice: String?

    enum CodingKeys: String, CodingKey {
        case clientSecret = "client_secret"
        case expiresAt = "expires_at"
        case sessionId = "session_id"
        case voice
    }
}
