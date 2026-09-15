import Foundation

struct GeminiFunctionResponse {
    let id: String
    let name: String
    let result: [String: Any]
}

struct GeminiToolTurnState {
    private(set) var outstandingCallIds = Set<String>()
    private(set) var handledCallIds = Set<String>()
    private(set) var pendingResponses: [GeminiFunctionResponse] = []

    var hasPendingResponses: Bool { !pendingResponses.isEmpty }

    mutating func reset() {
        outstandingCallIds.removeAll()
        handledCallIds.removeAll()
        pendingResponses.removeAll()
    }

    mutating func registerCall(id: String) -> Bool {
        guard !outstandingCallIds.contains(id), !handledCallIds.contains(id) else {
            return false
        }
        outstandingCallIds.insert(id)
        return true
    }

    mutating func queueResponse(_ response: GeminiFunctionResponse) -> Bool {
        guard !handledCallIds.contains(response.id) else { return false }
        handledCallIds.insert(response.id)
        outstandingCallIds.remove(response.id)
        pendingResponses.append(response)
        return true
    }

    mutating func drainResponses(
        appControl: String?
    ) -> [GeminiFunctionResponse]? {
        guard outstandingCallIds.isEmpty else { return nil }
        var responses = pendingResponses
        pendingResponses.removeAll()
        if let appControl, !appControl.isEmpty, !responses.isEmpty {
            var firstResult = responses[0].result
            firstResult["appControl"] = appControl
            responses[0] = GeminiFunctionResponse(
                id: responses[0].id,
                name: responses[0].name,
                result: firstResult
            )
        }
        return responses
    }
}

/// Foundation-only Gemini Live wire encoder/decoder.
/// Kept independent of URLSession so protocol fixtures exercise production JSON.
final class GeminiLiveCodec {
    private var responseSequence = 0
    private var emittedAudioDone = false

    func setupMessage(config: SessionConfig) -> [String: Any] {
        var sessionResumption: [String: Any] = [:]
        if let handle = config.resumptionHandle, !handle.isEmpty {
            sessionResumption["handle"] = handle
        }

        let declarations = config.tools.map { tool -> [String: Any] in
            [
                "name": tool.name,
                "description": tool.description,
                "behavior": "BLOCKING",
                "parameters": Self.geminiSchema(tool.parameters),
            ]
        }

        return [
            "setup": [
                "model": "models/\(config.model)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": [
                                "voiceName": config.voice,
                            ],
                        ],
                    ],
                ],
                "systemInstruction": [
                    "parts": [["text": config.instructions]],
                ],
                "tools": [[
                    "functionDeclarations": declarations,
                ]],
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "disabled": false,
                        "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
                        "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                        "prefixPaddingMs": 333,
                        "silenceDurationMs": 800,
                    ],
                    // A game-show question must finish before the answer
                    // window opens. CarPlay echo and eager player speech must
                    // not cancel a blocking tool turn and restart the question.
                    "activityHandling": "NO_INTERRUPTION",
                    "turnCoverage": "TURN_INCLUDES_ONLY_ACTIVITY",
                ],
                "sessionResumption": sessionResumption,
                "contextWindowCompression": [
                    "triggerTokens": 25_000,
                    "slidingWindow": ["targetTokens": 8_000],
                ],
                "inputAudioTranscription": [
                    "languageCodes": ["en-US"],
                    "mode": "VERBATIM",
                ],
                "outputAudioTranscription": [
                    "languageCodes": ["en-US"],
                    "mode": "VERBATIM",
                ],
            ] as [String: Any],
        ]
    }

    static func audioMessage(base64Audio: String) -> [String: Any] {
        [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": base64Audio,
                ],
            ],
        ]
    }

    static func audioStreamEndMessage() -> [String: Any] {
        ["realtimeInput": ["audioStreamEnd": true]]
    }

    static func controlMessage(instructions: String?) -> [String: Any] {
        let instruction = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = instruction?.isEmpty == false
            ? instruction!
            : "Continue with the next required game action."
        return [
            "clientContent": [
                "turns": [[
                    "role": "user",
                    "parts": [[
                        "text": "[APP_CONTROL]\n\(text)",
                    ]],
                ]],
                "turnComplete": true,
            ],
        ]
    }

    static func interruptMessage() -> [String: Any] {
        [
            "clientContent": [
                "turns": [[
                    "role": "user",
                    "parts": [[
                        "text": "[APP_CONTROL]\nStop the current response and wait silently for the next app instruction.",
                    ]],
                ]],
                "turnComplete": false,
            ],
        ]
    }

    static func exactSpeechMessage(text: String) -> [String: Any] {
        controlMessage(
            instructions: "Say this exact line in the current host voice, with no extra words: \(text)"
        )
    }

    static func toolResponseMessage(
        _ responses: [GeminiFunctionResponse]
    ) -> [String: Any] {
        [
            "toolResponse": [
                "functionResponses": responses.map {
                    [
                        "id": $0.id,
                        "name": $0.name,
                        "response": $0.result,
                    ] as [String: Any]
                },
            ],
        ]
    }

    func parse(_ data: Data) -> [RealtimeServerEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var events: [RealtimeServerEvent] = []

        if json["setupComplete"] != nil {
            events.append(.sessionCreated(sessionId: "gemini"))
            events.append(.sessionUpdated)
        }

        if let serverContent = json["serverContent"] as? [String: Any] {
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inlineData = part["inlineData"] as? [String: Any],
                       let audio = inlineData["data"] as? String {
                        events.append(.responseAudioDelta(
                            responseId: currentResponseId,
                            audio: audio
                        ))
                    }
                    if let text = part["text"] as? String, !text.isEmpty {
                        events.append(.responseAudioTranscriptDone(text: text))
                    }
                }
            }

            if let transcription = serverContent["inputTranscription"] as? [String: Any],
               let text = transcription["text"] as? String,
               !text.isEmpty {
                events.append(.responseAudioTranscriptDelta(text: text))
            }
            if let transcription = serverContent["outputTranscription"] as? [String: Any],
               let text = transcription["text"] as? String,
               !text.isEmpty {
                events.append(.responseAudioTranscriptDone(text: text))
            }

            events.append(contentsOf: voiceActivityEvents(from: serverContent))

            let interrupted = serverContent["interrupted"] as? Bool == true
            let generationComplete = serverContent["generationComplete"] as? Bool == true
            let turnComplete = serverContent["turnComplete"] as? Bool == true
            if interrupted {
                events.append(.responseInterrupted)
            }
            if interrupted || generationComplete || turnComplete {
                appendAudioDoneIfNeeded(to: &events)
            }
            if turnComplete {
                events.append(.responseDone)
                beginNextResponse()
            }
        }

        if let toolCall = json["toolCall"] as? [String: Any],
           let calls = toolCall["functionCalls"] as? [[String: Any]] {
            for call in calls {
                let id = call["id"] as? String ?? UUID().uuidString
                let name = call["name"] as? String ?? ""
                guard !name.isEmpty else { continue }
                let arguments: String
                if let args = call["args"] as? [String: Any],
                   let argsData = try? JSONSerialization.data(withJSONObject: args),
                   let encoded = String(data: argsData, encoding: .utf8) {
                    arguments = encoded
                } else if let encoded = call["args"] as? String {
                    arguments = encoded
                } else {
                    arguments = "{}"
                }
                events.append(.responseFunctionCallArgumentsDone(
                    callId: id,
                    name: name,
                    arguments: arguments
                ))
            }
        }

        if let cancellation = json["toolCallCancellation"] as? [String: Any],
           let ids = cancellation["ids"] as? [String] {
            events.append(contentsOf: ids.map {
                .error(message: "Tool call cancelled: \($0)", code: "tool_call_cancelled")
            })
        }

        if let update = json["sessionResumptionUpdate"] as? [String: Any],
           update["resumable"] as? Bool == true,
           let handle = update["newHandle"] as? String,
           !handle.isEmpty {
            events.append(.sessionResumptionUpdate(token: handle))
        }

        if let goAway = json["goAway"] as? [String: Any] {
            let timeLeft = Self.durationDescription(goAway["timeLeft"])
            events.append(.error(
                message: "Gemini Live server will disconnect in \(timeLeft)",
                code: "go_away"
            ))
        }

        if let usage = json["usageMetadata"] as? [String: Any] {
            let prompt = Self.intValue(usage["promptTokenCount"]) ?? 0
            let response = Self.intValue(usage["responseTokenCount"]) ?? 0
            let total = Self.intValue(usage["totalTokenCount"]) ?? (prompt + response)
            events.append(.usageMetadata(
                promptTokens: prompt,
                responseTokens: response,
                totalTokens: total,
                raw: usage
            ))
        }

        if let error = json["error"] as? [String: Any] {
            events.append(.error(
                message: error["message"] as? String ?? "Unknown Gemini Live error",
                code: error["code"] as? String ?? error["status"] as? String
            ))
        }

        if events.isEmpty {
            events.append(.unknown(type: json.keys.sorted().joined(separator: ",")))
        }
        return events
    }

    private var currentResponseId: String {
        "gemini-turn-\(responseSequence)"
    }

    private func appendAudioDoneIfNeeded(to events: inout [RealtimeServerEvent]) {
        guard !emittedAudioDone else { return }
        emittedAudioDone = true
        events.append(.responseAudioDone(responseId: currentResponseId))
    }

    private func beginNextResponse() {
        responseSequence += 1
        emittedAudioDone = false
    }

    private func voiceActivityEvents(
        from serverContent: [String: Any]
    ) -> [RealtimeServerEvent] {
        let raw: String?
        if let value = serverContent["voiceActivity"] as? String {
            raw = value
        } else if let value = serverContent["speechState"] as? String {
            raw = value
        } else if let value = serverContent["voiceActivity"] as? [String: Any] {
            raw = value["state"] as? String ?? value["type"] as? String
        } else {
            raw = nil
        }
        guard let normalized = raw?.uppercased() else { return [] }
        if normalized.contains("START") {
            return [.inputAudioBufferSpeechStarted]
        }
        if normalized.contains("END") || normalized.contains("STOP") {
            return [.inputAudioBufferSpeechStopped, .inputAudioBufferCommitted]
        }
        return []
    }

    private static func geminiSchema(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                if entry.key == "type", let type = entry.value as? String {
                    result[entry.key] = type.uppercased()
                } else {
                    result[entry.key] = geminiSchema(entry.value)
                }
            }
        }
        if let array = value as? [Any] {
            return array.map(geminiSchema)
        }
        return value
    }

    private static func durationDescription(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let dictionary = value as? [String: Any] {
            let seconds = intValue(dictionary["seconds"]) ?? 0
            let nanos = intValue(dictionary["nanos"]) ?? 0
            return String(format: "%.1fs", Double(seconds) + Double(nanos) / 1_000_000_000)
        }
        return "an unspecified interval"
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let integer = value as? Int { return integer }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
