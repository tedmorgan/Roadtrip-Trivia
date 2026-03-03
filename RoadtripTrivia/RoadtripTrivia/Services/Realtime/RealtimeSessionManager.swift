import Foundation
import Combine

/// Manages the WebSocket connection to the OpenAI Realtime API.
/// Handles ephemeral token generation (via Supabase), connection lifecycle,
/// audio streaming, and event dispatch.
class RealtimeSessionManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published private(set) var isConnected = false
    @Published private(set) var connectionError: String?

    // MARK: - Event Stream

    /// All parsed events from the Realtime API.
    let eventPublisher = PassthroughSubject<RealtimeServerEvent, Never>()

    // MARK: - Configuration

    private let supabaseURL = "https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1"
    private let realtimeURL = "wss://api.openai.com/v1/realtime"
    private let model = "gpt-4o-realtime-preview"

    // MARK: - Internal State

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var currentVoice: String = "alloy"
    private var currentSessionConfig: SessionConfig?
    private var isReceiving = false
    private var isReconnecting = false  // Guard against parallel reconnect chains
    private var intentionalDisconnect = false  // True when disconnect() called explicitly
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3  // Bug 29: reduce from 5 to avoid prolonged spin

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    // MARK: - Public API

    /// Full connection flow: fetch ephemeral token → connect WebSocket → send session config.
    func connect(sessionConfig: SessionConfig) async throws {
        connectionError = nil
        reconnectAttempts = 0
        intentionalDisconnect = false
        isReconnecting = false
        currentVoice = sessionConfig.voice
        currentSessionConfig = sessionConfig

        // Step 1: Get ephemeral token from Supabase
        let token = try await fetchEphemeralToken(voice: sessionConfig.voice)

        // Step 2: Connect WebSocket
        try await connectWebSocket(token: token)

        // Step 3: Send session configuration
        try await send(.sessionUpdate(sessionConfig))

        print("[Realtime] Session configured — ready for conversation")
    }

    /// Send a client event to the Realtime API.
    func send(_ event: RealtimeClientEvent) async throws {
        guard let ws = webSocketTask else {
            throw RealtimeError.notConnected
        }
        let data = try event.toData()
        // IMPORTANT: OpenAI Realtime API expects TEXT WebSocket frames, not binary
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw RealtimeError.sendFailed("Could not encode event as UTF-8 string")
        }
        // Bug 31: Log outgoing event types for diagnostics
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let eventType = json["type"] as? String,
           !eventType.contains("audio_buffer") {
            print("[Realtime] Sending: \(eventType)")
        }
        try await ws.send(.string(jsonString))
    }

    /// Send base64-encoded PCM16 audio to the API.
    func sendAudio(_ base64Audio: String) async throws {
        try await send(.inputAudioBufferAppend(audio: base64Audio))
    }

    /// Disconnect gracefully. Stops all reconnection attempts.
    func disconnect() {
        intentionalDisconnect = true
        isReceiving = false
        isReconnecting = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        currentSessionConfig = nil
        print("[Realtime] Disconnected")
    }

    /// Submit a function call result back to the model, then trigger a response.
    func submitFunctionResult(callId: String, result: [String: Any]) async throws {
        let resultJSON = try JSONSerialization.data(withJSONObject: result)
        let resultString = String(data: resultJSON, encoding: .utf8) ?? "{}"

        try await send(.conversationItemCreate(callId: callId, output: resultString))
        try await send(.responseCreate(instructions: nil))
    }

    // MARK: - Ephemeral Token

    private func fetchEphemeralToken(voice: String) async throws -> String {
        guard let url = URL(string: "\(supabaseURL)/realtime-token") else {
            throw RealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["voice": voice])

        print("[Realtime] Fetching ephemeral token...")
        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RealtimeError.tokenFetchFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
        }

        let tokenResponse = try JSONDecoder().decode(EphemeralTokenResponse.self, from: data)
        print("[Realtime] Ephemeral token obtained (session: \(tokenResponse.sessionId ?? "?"))")
        return tokenResponse.clientSecret
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket(token: String) async throws {
        guard var components = URLComponents(string: realtimeURL) else {
            throw RealtimeError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]

        guard let url = components.url else {
            throw RealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        webSocketTask = urlSession.webSocketTask(with: request)
        webSocketTask?.resume()

        // Start receiving messages
        isReceiving = true
        startReceiveLoop()

        // Wait for session.created event (with timeout)
        let created = try await waitForSessionCreated(timeout: 10)
        if !created {
            throw RealtimeError.connectionTimeout
        }

        isConnected = true
        reconnectAttempts = 0
        print("[Realtime] WebSocket connected")
    }

    private func waitForSessionCreated(timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            if isConnected { return true }
        }
        return isConnected
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        guard isReceiving, let ws = webSocketTask else { return }

        ws.receive { [weak self] result in
            guard let self, self.isReceiving else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.startReceiveLoop() // Continue receiving

            case .failure(let error):
                print("[Realtime] Receive error: \(error.localizedDescription)")
                self.handleDisconnect(source: "receive")
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d):
            data = d
        case .string(let s):
            data = Data(s.utf8)
        @unknown default:
            return
        }

        // Bug 31: Log raw event type for diagnostics
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let eventType = json["type"] as? String {
            // Only log non-audio events to avoid flooding the console
            if !eventType.contains("audio.delta") && !eventType.contains("audio_buffer") {
                print("[Realtime] Event: \(eventType)")
            }
            // Log response.done status to diagnose empty responses
            if eventType == "response.done",
               let response = json["response"] as? [String: Any] {
                let status = response["status"] as? String ?? "?"
                let statusDetails = response["status_details"] as? [String: Any]
                let reason = statusDetails?["reason"] as? String
                    ?? statusDetails?["error"] as? String
                    ?? (statusDetails.map { "\($0)" } ?? "none")
                print("[Realtime] Response status: \(status), details: \(reason)")
            }
        }

        guard let event = RealtimeServerEvent.parse(from: data) else {
            // Bug 31: Show what we couldn't parse
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            print("[Realtime] Unparseable event: \(preview)")
            return
        }

        // Handle connection-level events internally
        switch event {
        case .sessionCreated:
            isConnected = true
        case .error(let message, let code):
            print("[Realtime] API error [\(code ?? "?")]: \(message)")
            connectionError = message
        default:
            break
        }

        // Dispatch all events to subscribers
        eventPublisher.send(event)
    }

    // MARK: - Reconnection

    private func handleDisconnect(source: String) {
        isConnected = false

        // Don't reconnect if we intentionally disconnected
        guard !intentionalDisconnect else {
            print("[Realtime] Intentional disconnect — not reconnecting (source: \(source))")
            return
        }

        // Prevent parallel reconnect chains: only one source gets to reconnect
        guard !isReconnecting else {
            print("[Realtime] Already reconnecting — ignoring duplicate disconnect (source: \(source))")
            return
        }

        guard reconnectAttempts < maxReconnectAttempts else {
            print("[Realtime] Max reconnect attempts (\(maxReconnectAttempts)) reached — giving up")
            connectionError = "Connection lost. Please try again."
            // Bug 29: Clean up completely so the app isn't stuck in a broken state
            isReconnecting = false
            webSocketTask = nil
            eventPublisher.send(.error(message: "Connection lost after \(maxReconnectAttempts) retries", code: "reconnect_failed"))
            return
        }

        isReconnecting = true
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 15.0) // Bug 29: cap delay at 15s, not 30s
        print("[Realtime] Reconnecting in \(delay)s (attempt \(reconnectAttempts)/\(maxReconnectAttempts), source: \(source))...")

        // Clean up old socket
        isReceiving = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalDisconnect else {
                self?.isReconnecting = false
                return
            }

            Task {
                do {
                    let freshToken = try await self.fetchEphemeralToken(voice: self.currentVoice)
                    try await self.connectWebSocket(token: freshToken)

                    if let config = self.currentSessionConfig {
                        try await self.send(.sessionUpdate(config))
                    }

                    self.isReconnecting = false
                    print("[Realtime] Reconnected successfully")
                } catch {
                    print("[Realtime] Reconnection failed: \(error.localizedDescription)")
                    self.isReconnecting = false
                    // Bug 29: Non-recursive retry — schedule next attempt via handleDisconnect
                    self.handleDisconnect(source: "reconnect_retry")
                }
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension RealtimeSessionManager: URLSessionWebSocketDelegate {

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        print("[Realtime] WebSocket opened")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        print("[Realtime] WebSocket closed: \(closeCode.rawValue) reason: \(reasonStr)")
        handleDisconnect(source: "didClose")
    }
}

// MARK: - Errors

enum RealtimeError: LocalizedError {
    case invalidURL
    case notConnected
    case tokenFetchFailed(String)
    case connectionTimeout
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Realtime API URL"
        case .notConnected: return "Not connected to Realtime API"
        case .tokenFetchFailed(let detail): return "Failed to get session token: \(detail)"
        case .connectionTimeout: return "Connection timed out"
        case .sendFailed(let detail): return "Send failed: \(detail)"
        }
    }
}
