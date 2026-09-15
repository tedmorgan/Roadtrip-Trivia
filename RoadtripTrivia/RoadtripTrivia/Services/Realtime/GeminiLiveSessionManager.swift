import Foundation
import Combine

/// Direct iOS WebSocket adapter for Gemini 3.8 Live.
final class GeminiLiveSessionManager: NSObject, ObservableObject, LiveSessionManaging {
    @Published private(set) var isConnected = false
    @Published private(set) var connectionError: String?

    var isConnectedPublisher: AnyPublisher<Bool, Never> {
        $isConnected.eraseToAnyPublisher()
    }
    let eventPublisher = PassthroughSubject<RealtimeServerEvent, Never>()

    var autoReconnectDisabled = false
    private(set) var lastCloseInfo: String?
    private(set) var lastResumptionToken: String?
    var hasPendingResults: Bool { toolTurnState.hasPendingResponses }

    private let supabaseURL =
        "https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1"
    private let webSocketBase =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained"

    private var urlSession: URLSession!
    private var webSocketTask: URLSessionWebSocketTask?
    private var codec = GeminiLiveCodec()
    private var currentSessionConfig: SessionConfig?
    private var isReceiving = false
    private var intentionalDisconnect = false
    private var setupComplete = false
    private var hasEmittedDisconnect = false
    private var consecutiveSendFailures = 0
    private let maxConsecutiveSendFailures = 3
    private var toolTurnState = GeminiToolTurnState()
    private var pingTimer: DispatchSourceTimer?
    private let apiLogger = APIUsageLogger.shared

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3600
        urlSession = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: .main
        )
    }

    func connect(sessionConfig: SessionConfig) async throws {
        connectionError = nil
        lastCloseInfo = nil
        intentionalDisconnect = false
        setupComplete = false
        hasEmittedDisconnect = false
        consecutiveSendFailures = 0
        codec = GeminiLiveCodec()
        currentSessionConfig = sessionConfig
        toolTurnState.reset()

        print("[GeminiLive] Starting Gemini 3.8 Live connection")
        apiLogger.configureProvider("gemini", model: sessionConfig.model)
        let token = try await fetchEphemeralToken()
        try await openWebSocket(token: token.value)
        try await sendRaw(codec.setupMessage(config: sessionConfig))
        guard try await waitForSetupComplete(timeout: 15) else {
            throw RealtimeError.connectionTimeout
        }
        isConnected = true
        print("[GeminiLive] Session configured with \(sessionConfig.voice)")
    }

    func send(_ event: RealtimeClientEvent) async throws {
        switch event {
        case .sessionUpdate:
            return
        case .inputAudioBufferAppend(let audio):
            try await sendRaw(GeminiLiveCodec.audioMessage(base64Audio: audio), noisy: true)
        case .inputAudioBufferClear:
            return
        case .responseCreate(let instructions):
            try await sendRaw(GeminiLiveCodec.controlMessage(instructions: instructions))
        case .conversationItemCreate(let callId, let name, let output):
            let result = (try? JSONSerialization.jsonObject(with: Data(output.utf8)))
                as? [String: Any] ?? ["result": output]
            try await sendRaw(GeminiLiveCodec.toolResponseMessage([
                GeminiFunctionResponse(id: callId, name: name, result: result),
            ]))
        case .forceMessage(let text, _):
            try await sendRaw(GeminiLiveCodec.exactSpeechMessage(text: text))
        case .transcriptionKeyterms:
            // Gemini's transcription configuration is fixed at setup time.
            return
        case .responseCancel:
            try await sendRaw(GeminiLiveCodec.interruptMessage())
        }
    }

    func sendAudio(_ base64Audio: String) async throws {
        do {
            try await send(.inputAudioBufferAppend(audio: base64Audio))
            apiLogger.recordInputAudio(
                bytes: Data(base64Encoded: base64Audio)?.count ?? 0
            )
            consecutiveSendFailures = 0
        } catch {
            consecutiveSendFailures += 1
            if consecutiveSendFailures >= maxConsecutiveSendFailures {
                consecutiveSendFailures = 0
                handleDisconnect(source: "audio_send_failures")
            }
            throw error
        }
    }

    func disconnect(preserveResumptionToken: Bool) {
        intentionalDisconnect = true
        isReceiving = false
        stopPingTimer()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        setupComplete = false
        currentSessionConfig = nil
        toolTurnState.reset()
        if !preserveResumptionToken {
            lastResumptionToken = nil
        }
        print("[GeminiLive] Disconnected (preserveToken=\(preserveResumptionToken))")
        apiLogger.logConnectionEvent("disconnect preserve_resumption=\(preserveResumptionToken)")
    }

    func submitFunctionResult(
        callId: String,
        result: [String: Any],
        name: String
    ) async throws {
        try await queueFunctionResult(callId: callId, result: result, name: name)
        try await flushPendingResults(instructions: nil)
    }

    func queueFunctionResult(
        callId: String,
        result: [String: Any],
        name: String
    ) async throws {
        guard toolTurnState.queueResponse(
            GeminiFunctionResponse(id: callId, name: name, result: result)
        ) else { return }
        print(
            "[GeminiLive] Queued \(name) result " +
            "(pending=\(toolTurnState.pendingResponses.count), outstanding=\(toolTurnState.outstandingCallIds.count))"
        )
    }

    func flushPendingResults(instructions: String?) async throws {
        guard let responses = toolTurnState.drainResponses(appControl: instructions) else {
            print(
                "[GeminiLive] Tool flush deferred " +
                "(outstanding=\(toolTurnState.outstandingCallIds.count))"
            )
            return
        }

        if responses.isEmpty {
            if let instructions, !instructions.isEmpty {
                try await sendRaw(GeminiLiveCodec.controlMessage(instructions: instructions))
            }
            return
        }

        try await sendRaw(GeminiLiveCodec.toolResponseMessage(responses))
        print("[GeminiLive] Sent \(responses.count) blocking tool response(s)")
    }

    private func fetchEphemeralToken() async throws -> GeminiLiveTokenResponse {
        guard let url = URL(string: "\(supabaseURL)/gemini-live-token") else {
            throw RealtimeError.invalidURL
        }
        guard let accessToken = AuthService.shared.currentToken, !accessToken.isEmpty else {
            throw RealtimeError.tokenFetchFailed("Authentication required")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            AuthService.shared.supabaseApiKey,
            forHTTPHeaderField: "apikey"
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RealtimeError.tokenFetchFailed(
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)"
            )
        }
        return try JSONDecoder().decode(GeminiLiveTokenResponse.self, from: data)
    }

    private func openWebSocket(token: String) async throws {
        guard var components = URLComponents(string: webSocketBase) else {
            throw RealtimeError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let url = components.url else {
            throw RealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        webSocketTask = urlSession.webSocketTask(with: request)
        webSocketTask?.resume()
        isReceiving = true
        startReceiveLoop()
        startPingTimer()
    }

    private func waitForSetupComplete(timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if setupComplete { return true }
            if webSocketTask == nil {
                throw RealtimeError.sendFailed(
                    lastCloseInfo ?? "Connection closed before setup completed"
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return setupComplete
    }

    private func sendRaw(_ json: [String: Any], noisy: Bool = false) async throws {
        guard let webSocketTask else { throw RealtimeError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeError.sendFailed("Could not encode Gemini JSON")
        }
        if !noisy {
            print("[GeminiLive] Sending: \(json.keys.sorted().joined(separator: ","))")
        }
        try await webSocketTask.send(.string(text))
    }

    private func startReceiveLoop() {
        guard isReceiving, let webSocketTask else { return }
        webSocketTask.receive { [weak self] result in
            guard let self, self.isReceiving, webSocketTask === self.webSocketTask else {
                return
            }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.startReceiveLoop()
            case .failure(let error):
                self.lastCloseInfo = "receiveError: \(error.localizedDescription)"
                self.handleDisconnect(source: "receive")
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            data = Data(value.utf8)
        @unknown default:
            return
        }

        let events = codec.parse(data)
        for event in events {
            switch event {
            case .sessionUpdated:
                setupComplete = true
                isConnected = true
            case .sessionResumptionUpdate(let token):
                lastResumptionToken = token
            case .responseFunctionCallArgumentsDone(let callId, _, _):
                guard toolTurnState.registerCall(id: callId) else {
                    continue
                }
            case .responseAudioDelta(_, let audio):
                apiLogger.recordOutputAudio(
                    bytes: Data(base64Encoded: audio)?.count ?? 0
                )
            case .error(let message, _):
                connectionError = message
            default:
                break
            }
            eventPublisher.send(event)
        }
    }

    private func startPingTimer() {
        stopPingTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 8, repeating: 8)
        timer.setEventHandler { [weak self] in self?.sendPing() }
        timer.resume()
        pingTimer = timer
    }

    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func sendPing() {
        guard let webSocketTask else { return }
        webSocketTask.sendPing { [weak self] error in
            if let error {
                self?.lastCloseInfo = "pingError: \(error.localizedDescription)"
                self?.handleDisconnect(source: "ping")
            }
        }
    }

    private func handleDisconnect(source: String) {
        stopPingTimer()
        isConnected = false
        guard !intentionalDisconnect else { return }
        guard !hasEmittedDisconnect else { return }
        hasEmittedDisconnect = true
        isReceiving = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        let detail = lastCloseInfo ?? "unknown"
        eventPublisher.send(.error(
            message: "WebSocket disconnected [\(source)] \(detail)",
            code: autoReconnectDisabled
                ? "websocket_disconnected"
                : "reconnect_failed"
        ))
        apiLogger.logConnectionEvent("disconnect source=\(source)")
    }
}

extension GeminiLiveSessionManager: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask task: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard task === webSocketTask else { return }
        print("[GeminiLive] WebSocket opened")
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask task: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard task === webSocketTask else { return }
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        lastCloseInfo = "code=\(closeCode.rawValue) reason=\(reasonText)"
        handleDisconnect(source: "didClose:\(closeCode.rawValue)")
    }
}
