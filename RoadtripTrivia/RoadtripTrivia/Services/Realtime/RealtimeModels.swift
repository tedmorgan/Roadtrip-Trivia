import Foundation

// MARK: - Client → Server Events (Gemini Live API)

/// Wrapper for all events sent to the Gemini Live API over WebSocket.
/// Cases mirror the original OpenAI Realtime event model so the coordinator
/// layer stays unchanged; serialisation targets Gemini's BidiGenerateContent
/// wire format instead.
enum RealtimeClientEvent {

    /// Initial session setup – sent as the very first WebSocket message.
    /// Gemini equivalent of OpenAI's `session.update`.
    case sessionUpdate(SessionConfig)

    /// Append a chunk of base64-encoded PCM16 audio from the microphone.
    case inputAudioBufferAppend(audio: String)

    /// Clear the audio buffer (unused in practice).
    case inputAudioBufferClear

    /// Inject instructions into the conversation as a user turn.
    /// Gemini has no `response.create`; instead we send `clientContent`.
    /// When `instructions` is nil this is a no-op (model auto-continues).
    case responseCreate(instructions: String?)

    /// Provide the result of a function call back to the model.
    /// In Gemini these are batched into a single `toolResponse`; the session
    /// manager collects them, but this case is kept for compatibility.
    case conversationItemCreate(callId: String, name: String, output: String)

    /// Interrupt the model's current generation.
    /// Gemini equivalent: send `clientContent` with `turnComplete: true`.
    case responseCancel

    func toJSON() -> [String: Any]? {
        switch self {
        case .sessionUpdate(let config):
            var generationConfig: [String: Any] = [
                "responseModalities": ["AUDIO"],
            ]
            if let speechConfig = config.speechConfig {
                generationConfig["speechConfig"] = speechConfig
            }

            var setup: [String: Any] = [
                "model": "models/\(config.model)",
                "generationConfig": generationConfig,
                "systemInstruction": [
                    "parts": [["text": config.instructions]]
                ] as [String: Any],
            ]

            if !config.tools.isEmpty {
                setup["tools"] = [
                    ["functionDeclarations": config.tools.map { $0.toDictionary() }]
                ]
            }

            // START_SENSITIVITY_LOW: the server VAD must hear confident
            // speech onset before declaring a turn/interruption. HIGH was
            // trigger-happy in a moving car — cabin noise and speaker echo
            // tripped `interrupted` events that cut the host off mid-sentence
            // (the #1 reported defect). The client-side pre-roll buffer
            // covers any onset the lower sensitivity might delay.
            setup["realtimeInputConfig"] = [
                "automaticActivityDetection": [
                    "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
                    "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                    "silenceDurationMs": 800,
                    "prefixPaddingMs": 100
                ] as [String: Any]
            ] as [String: Any]

            setup["outputAudioTranscription"] = [String: Any]()

            // Sliding-window context compression — configured purely as a
            // SAFETY NET near the model's hard context ceiling, NOT as an
            // active cost-control mechanism.
            //
            // History: a low trigger (25.6K) compressed the conversation ~5x
            // per game. Each compression event discarded recent turns
            // mid-flow, which the docs warn can make the model "slow down or
            // hallucinate" — observed directly as multi-second dead pauses,
            // host confusion, cut-off reactions, and the R3 freeze
            // (debug-f3b222.log 2026-06-24). See the token collapse
            // 48,931 -> 17,053 right when the host stalled.
            //
            // UX-first decision (2026-06-25): retain full context for the
            // entire game so the host never loses conversational state.
            // A real game (up to ~5 rounds) peaks around ~40K tokens; with a
            // 100K trigger compression effectively NEVER fires in normal play.
            // It only engages for marathon sessions, keeping 60K of recent
            // context (gentle) and firing BEFORE the hard ceiling so the
            // session is never force-closed mid-turn ("WS closed by server").
            //
            // CRITICAL ENCODING (2026-06-30): `triggerTokens` and
            // `targetTokens` are int64 in the Gemini Live proto, which the
            // JSON/proto mapping requires to be sent as STRINGS. Sent as raw
            // numbers they are silently dropped and the server falls back to
            // its low default trigger — which is exactly what was happening:
            // compression fired at ~22-37K mid-game (well below 100K),
            // injecting 13-15s latency spikes on the turn right after each
            // compression (debug-f3b222.log 2026-06-29). Context reaching
            // 37,240 tokens with no force-close confirms the real window is
            // far above 100K, so the string-encoded trigger keeps compression
            // dormant for a normal game.
            setup["contextWindowCompression"] = [
                "triggerTokens": "100000",
                "slidingWindow": ["targetTokens": "60000"] as [String: Any]
            ] as [String: Any]

            if let handle = config.resumptionHandle {
                setup["sessionResumption"] = ["handle": handle] as [String: Any]
            } else {
                setup["sessionResumption"] = [String: Any]()
            }

            if let cacheName = config.cachedContentName {
                setup["cachedContent"] = cacheName
            }

            return ["setup": setup]

        case .inputAudioBufferAppend(let audio):
            return [
                "realtimeInput": [
                    "audio": [
                        "data": audio,
                        "mimeType": "audio/pcm;rate=16000"
                    ] as [String: Any]
                ] as [String: Any]
            ]

        case .inputAudioBufferClear:
            return nil

        case .responseCreate(let instructions):
            guard let instructions else { return nil }
            return [
                "realtimeInput": [
                    "text": instructions
                ] as [String: Any]
            ]

        case .conversationItemCreate:
            return nil

        case .responseCancel:
            return [
                "realtimeInput": [
                    "text": "[stop]"
                ] as [String: Any]
            ]
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
    /// When set, Gemini restores server-side conversation context from a prior session.
    var resumptionHandle: String?
    /// When set, references a server-side CachedContent resource containing the
    /// policy block, so only the memory block needs to go in `systemInstruction`.
    var cachedContentName: String?

    /// Optional Gemini speech config (voice selection).
    var speechConfig: [String: Any]? {
        guard !voice.isEmpty else { return nil }
        return [
            "voiceConfig": [
                "prebuiltVoiceConfig": [
                    "voiceName": voice
                ]
            ]
        ]
    }

    init(instructions: String, voice: String, tools: [RealtimeTool], model: String = "gemini-3.1-flash-live-preview", resumptionHandle: String? = nil, cachedContentName: String? = nil) {
        self.instructions = instructions
        self.voice = voice
        self.tools = tools
        self.model = model
        self.resumptionHandle = resumptionHandle
        self.cachedContentName = cachedContentName
    }
}

struct RealtimeTool {
    let name: String
    let description: String
    let parameters: [String: Any]

    /// Gemini FunctionDeclaration format.
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "description": description,
        ]
        if !parameters.isEmpty {
            dict["parameters"] = parameters
        }
        return dict
    }
}

// MARK: - Server → Client Events (Gemini Live API)

/// Parsed event received from the Gemini Live API.
/// Cases mirror the original OpenAI model so the coordinator stays unchanged.
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

    /// Parse a Gemini `BidiGenerateContentServerMessage` into our internal event model.
    static func parse(from data: Data) -> [RealtimeServerEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var events: [RealtimeServerEvent] = []

        // 1. Setup complete → treated as session created
        if json["setupComplete"] != nil {
            events.append(.sessionCreated(sessionId: "gemini"))
            return events
        }

        // 2. Tool calls — emit one event per function call, then a synthetic
        //    responseDone so the coordinator flushes the batched toolResponse.
        //    Gemini waits for our toolResponse before continuing (synchronous FC).
        if let toolCall = json["toolCall"] as? [String: Any],
           let functionCalls = toolCall["functionCalls"] as? [[String: Any]] {
            for fc in functionCalls {
                let callId = fc["id"] as? String ?? UUID().uuidString
                let name = fc["name"] as? String ?? ""
                let args = fc["args"] as? [String: Any] ?? [:]
                let argsString: String
                if let argsData = try? JSONSerialization.data(withJSONObject: args),
                   let s = String(data: argsData, encoding: .utf8) {
                    argsString = s
                } else {
                    argsString = "{}"
                }
                events.append(.responseFunctionCallArgumentsDone(callId: callId, name: name, arguments: argsString))
            }
            events.append(.responseDone)
            return events
        }

        // 3. Tool call cancellation
        if let cancellation = json["toolCallCancellation"] as? [String: Any],
           let ids = cancellation["ids"] as? [String] {
            for id in ids {
                events.append(.error(message: "Tool call cancelled: \(id)", code: "tool_call_cancelled"))
            }
            return events
        }

        // 4. Go away notice
        if json["goAway"] != nil {
            events.append(.error(message: "Server is closing the connection soon", code: "go_away"))
            return events
        }

        // 5. Session resumption update — extract and surface the token
        if let resumption = json["sessionResumptionUpdate"] as? [String: Any],
           let handle = resumption["newHandle"] as? String {
            events.append(.sessionResumptionUpdate(token: handle))
            return events
        }

        // 6. Usage metadata (can accompany any message — always check)
        if let usage = json["usageMetadata"] as? [String: Any] {
            let prompt = usage["promptTokenCount"] as? Int ?? 0
            let response = usage["candidatesTokenCount"] as? Int
                          ?? usage["responseTokenCount"] as? Int ?? 0
            let total = usage["totalTokenCount"] as? Int ?? (prompt + response)
            events.append(.usageMetadata(promptTokens: prompt, responseTokens: response,
                                         totalTokens: total, raw: usage))
        }

        // 7. Server content
        if let serverContent = json["serverContent"] as? [String: Any] {

            // Interrupted → equivalent to speech_started (barge-in)
            if let interrupted = serverContent["interrupted"] as? Bool, interrupted {
                events.append(.inputAudioBufferSpeechStarted)
            }

            // Model turn with audio data
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inlineData = part["inlineData"] as? [String: Any],
                       let audioBase64 = inlineData["data"] as? String {
                        events.append(.responseAudioDelta(responseId: "gemini", audio: audioBase64))
                    }
                }
            }

            // Input transcription
            if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
               let text = inputTranscription["text"] as? String, !text.isEmpty {
                events.append(.responseAudioTranscriptDelta(text: text))
            }

            // Output transcription
            if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
               let text = outputTranscription["text"] as? String, !text.isEmpty {
                events.append(.responseAudioTranscriptDone(text: text))
            }

            // Generation complete (audio stream done for this turn)
            if let genComplete = serverContent["generationComplete"] as? Bool, genComplete {
                events.append(.responseAudioDone(responseId: "gemini"))
            }

            // Turn complete → equivalent to response.done
            if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
                if !events.contains(where: {
                    if case .responseAudioDone = $0 { return true }
                    return false
                }) {
                    events.append(.responseAudioDone(responseId: "gemini"))
                }
                events.append(.responseDone)
            }
        }

        if events.isEmpty {
            let keys = Array(json.keys).joined(separator: ", ")
            events.append(.unknown(type: "gemini:\(keys)"))
        }

        return events
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

struct GeminiTokenResponse: Codable {
    let apiKey: String
    let model: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model
    }
}
