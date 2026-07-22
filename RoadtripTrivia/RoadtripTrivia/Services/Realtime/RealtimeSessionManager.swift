import Foundation
import Combine

// #region agent log
private let _dbgWSPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first! + "/debug-30dda1.log"
private func _dbgWS(_ loc: String, _ msg: String, _ data: [String: Any] = [:]) {
    let entry: [String: Any] = ["sessionId":"30dda1","hypothesisId":"WS","location":loc,"message":msg,"data":data,"timestamp":Date().timeIntervalSince1970*1000]
    guard let d = try? JSONSerialization.data(withJSONObject: entry), let line = String(data: d, encoding: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: _dbgWSPath) { FileManager.default.createFile(atPath: _dbgWSPath, contents: nil) }
    guard let h = FileHandle(forWritingAtPath: _dbgWSPath) else { return }
    h.seekToEndOfFile(); h.write((line+"\n").data(using:.utf8)!); h.closeFile()
}
// #endregion

/// Manages the WebSocket connection to the Gemini Live API.
/// Handles API key retrieval (via Supabase), connection lifecycle,
/// audio streaming, and event dispatch.
class RealtimeSessionManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published private(set) var isConnected = false
    @Published private(set) var connectionError: String?

    // MARK: - Event Stream

    /// All parsed events from the Gemini Live API.
    let eventPublisher = PassthroughSubject<RealtimeServerEvent, Never>()

    // MARK: - Configuration

    private let supabaseURL = "https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1"
    private let geminiWSBase = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    // MARK: - Internal State

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var currentVoice: String = "Puck"
    private var currentSessionConfig: SessionConfig?
    private var isReceiving = false
    private var isReconnecting = false
    private var intentionalDisconnect = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3
    /// When true, the session manager does NOT auto-reconnect on WebSocket drop.
    /// The coordinator manages reconnection with full game context instead.
    var autoReconnectDisabled = false
    /// Guards against sending hundreds of duplicate disconnect events when
    /// many audio send failures arrive after the socket is already dead.
    private var hasEmittedDisconnectEvent = false

    /// Buffered tool responses waiting to be sent as a batch.
    private var pendingToolResponses: [(id: String, name: String, result: [String: Any])] = []

    /// Captures the close reason when the WebSocket is terminated by the server
    /// so `waitForSetupComplete` can fail fast instead of waiting for timeout.
    private var earlyCloseReason: String?

    /// Stores the last close code/reason for diagnostics regardless of connection state.
    private(set) var lastCloseInfo: String?

    /// Consecutive audio send failures — triggers disconnect after threshold.
    private var consecutiveSendFailures = 0
    private let maxConsecutiveSendFailures = 3

    /// Most recent session resumption token from Gemini. Used to restore
    /// server-side conversation context on reconnect.
    private(set) var lastResumptionToken: String?

    /// Most recent API key, retained for cache cleanup on disconnect.
    private var lastApiKey: String?

    /// Timer for sending periodic WebSocket keepalive pings.
    private var pingTimer: DispatchSourceTimer?

    private let apiLogger = APIUsageLogger.shared

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    // MARK: - Public API

    /// Full connection flow: fetch API key → (optionally cache policy) → connect WebSocket → send setup.
    func connect(sessionConfig: SessionConfig) async throws {
        connectionError = nil
        earlyCloseReason = nil
        lastCloseInfo = nil
        reconnectAttempts = 0
        consecutiveSendFailures = 0
        intentionalDisconnect = false
        isReconnecting = false
        hasEmittedDisconnectEvent = false
        currentVoice = sessionConfig.voice

        var config = sessionConfig

        print("[Realtime] ── Starting Gemini connection flow ──")

        // Step 1: Get API key from Supabase
        let apiKey = try await fetchGeminiApiKey()
        lastApiKey = apiKey

        // Step 2: Attempt to cache the policy block (no-op when disabled)
        if config.cachedContentName == nil {
            let policyBlock = SystemPromptBuilder.buildPolicyBlock()
            if let cacheName = await GeminiCacheService.shared.ensureCache(
                policyText: policyBlock, model: config.model, apiKey: apiKey
            ) {
                config.cachedContentName = cacheName
                let memoryOnly = SystemPromptBuilder.buildMemoryBlock(locationLabel: nil)
                print("[Realtime] Policy block cached — instructions reduced from \(config.instructions.count) to \(memoryOnly.count) chars")
            }
        }

        currentSessionConfig = config

        // Step 3: Connect WebSocket
        try await connectWebSocket(apiKey: apiKey)

        // Step 4: Send setup message (must be first message)
        try await sendSetup(config)

        print("[Realtime] Gemini session configured — ready for conversation")
    }

    /// Send a client event to the Gemini Live API.
    func send(_ event: RealtimeClientEvent) async throws {
        guard let ws = webSocketTask else {
            throw RealtimeError.notConnected
        }
        let data = try event.toData()
        if data.isEmpty { return }

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw RealtimeError.sendFailed("Could not encode event as UTF-8 string")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let keys = Array(json.keys).joined(separator: ", ")
            if !keys.contains("realtimeInput") {
                print("[Realtime] Sending: \(keys)")
            }
        }

        try await ws.send(.string(jsonString))
    }

    /// Send base64-encoded PCM16 audio to the API (16kHz for Gemini).
    func sendAudio(_ base64Audio: String) async throws {
        do {
            try await send(.inputAudioBufferAppend(audio: base64Audio))
            consecutiveSendFailures = 0
        } catch {
            consecutiveSendFailures += 1
            if consecutiveSendFailures >= maxConsecutiveSendFailures {
                print("[Realtime] \(consecutiveSendFailures) consecutive audio send failures — triggering disconnect")
                consecutiveSendFailures = 0
                handleDisconnect(source: "audio_send_failures")
            }
            throw error
        }
    }

    /// Disconnect gracefully. Stops all reconnection attempts.
    /// Set `preserveResumptionToken` to keep the token for coordinator-managed reconnects.
    func disconnect(preserveResumptionToken: Bool = false) {
        intentionalDisconnect = true
        isReceiving = false
        isReconnecting = false
        earlyCloseReason = nil
        stopPingTimer()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        currentSessionConfig = nil
        pendingToolResponses.removeAll()
        if !preserveResumptionToken {
            lastResumptionToken = nil
            if let key = lastApiKey {
                GeminiCacheService.shared.invalidate(apiKey: key)
            }
            lastApiKey = nil
        }
        print("[Realtime] Disconnected (preserveToken=\(preserveResumptionToken))")
    }

    /// Submit a function call result AND immediately trigger model continuation.
    /// Used for cases needing the LLM to respond right away (end_game, hint denial).
    func submitFunctionResult(callId: String, result: [String: Any], name: String = "") async throws {
        let response = buildToolResponse(id: callId, name: name, result: result)
        try await sendRawJSON(response)
    }

    /// Queue a function call result WITHOUT sending yet.
    /// Call flushPendingResults() to send all queued results as one toolResponse.
    func queueFunctionResult(callId: String, result: [String: Any], name: String = "") async throws {
        pendingToolResponses.append((id: callId, name: name, result: result))
        hasPendingResults = true
    }

    /// Send all queued tool responses as a single `toolResponse` message.
    /// If `instructions` is set, follow with a `realtimeInput.text` message.
    func flushPendingResults(instructions: String? = nil) async throws {
        let hadPending = hasPendingResults
        let responses = pendingToolResponses
        pendingToolResponses.removeAll()
        if hadPending { hasPendingResults = false }

        if !responses.isEmpty {
            let functionResponses = responses.map { resp -> [String: Any] in
                [
                    "id": resp.id,
                    "name": resp.name,
                    "response": ["result": resp.result]
                ] as [String: Any]
            }
            let message: [String: Any] = [
                "toolResponse": [
                    "functionResponses": functionResponses
                ]
            ]
            try await sendRawJSON(message)
        }

        if let instructions {
            try await send(.responseCreate(instructions: instructions))
        }
    }

    private(set) var hasPendingResults = false

    // MARK: - Raw JSON Sending

    private func sendRawJSON(_ json: [String: Any]) async throws {
        guard let ws = webSocketTask else {
            throw RealtimeError.notConnected
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw RealtimeError.sendFailed("Could not encode JSON as UTF-8 string")
        }
        print("[Realtime] Sending raw: \(Array(json.keys).joined(separator: ", "))")
        try await ws.send(.string(jsonString))
    }

    // MARK: - Gemini API Key

    private func fetchGeminiApiKey() async throws -> String {
        guard let url = URL(string: "\(supabaseURL)/gemini-token") else {
            throw RealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        print("[Realtime] Fetching Gemini API key...")
        // #region agent log
        _dbgWS("RSM:fetchKey", "H1: fetching API key", ["url": "\(supabaseURL)/gemini-token"])
        // #endregion
        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // #region agent log
            _dbgWS("RSM:fetchKey", "H1: API key fetch FAILED", ["status": (response as? HTTPURLResponse)?.statusCode ?? 0, "body": String(body.prefix(200))])
            // #endregion
            throw RealtimeError.tokenFetchFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
        }

        let tokenResponse = try JSONDecoder().decode(GeminiTokenResponse.self, from: data)
        // #region agent log
        _dbgWS("RSM:fetchKey", "H1/H3: API key obtained", ["model": tokenResponse.model, "keyPrefix": String(tokenResponse.apiKey.prefix(8))])
        // #endregion
        print("[Realtime] Gemini API key obtained (model: \(tokenResponse.model))")
        return tokenResponse.apiKey
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket(apiKey: String) async throws {
        guard var components = URLComponents(string: geminiWSBase) else {
            throw RealtimeError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let url = components.url else {
            throw RealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        // #region agent log
        _dbgWS("RSM:connectWS", "H2/H3/H5: opening WebSocket", ["url": url.absoluteString.replacingOccurrences(of: apiKey, with: "***")])
        // #endregion
        webSocketTask = urlSession.webSocketTask(with: request)
        webSocketTask?.resume()

        isReceiving = true
        startReceiveLoop()
        startPingTimer()

        print("[Realtime] Gemini WebSocket opened, waiting for setupComplete...")
    }

    private func sendSetup(_ config: SessionConfig) async throws {
        guard let json = RealtimeClientEvent.sessionUpdate(config).toJSON() else {
            throw RealtimeError.sendFailed("Failed to build setup message")
        }
        // #region agent log
        let setupData = try? JSONSerialization.data(withJSONObject: json)
        let setupSize = setupData?.count ?? 0
        let promptLen = config.instructions.count
        _dbgWS("RSM:sendSetup", "H2/H4: sending setup message", ["setupJsonBytes": setupSize, "promptChars": promptLen, "model": config.model, "voice": config.voice, "toolCount": config.tools.count])
        // #endregion
        try await sendRawJSON(json)
        // #region agent log
        _dbgWS("RSM:sendSetup", "H2: setup message sent OK, waiting for setupComplete")
        // #endregion

        let created = try await waitForSetupComplete(timeout: 15)
        if !created {
            // #region agent log
            _dbgWS("RSM:sendSetup", "H2: setupComplete TIMEOUT", ["earlyClose": earlyCloseReason ?? "none"])
            // #endregion
            throw RealtimeError.connectionTimeout
        }

        isConnected = true
        reconnectAttempts = 0
        print("[Realtime] Gemini session setup complete")
    }

    private func waitForSetupComplete(timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            if isConnected { return true }
            if let reason = earlyCloseReason {
                throw RealtimeError.sendFailed("WebSocket closed by server: \(reason)")
            }
            if webSocketTask == nil {
                throw RealtimeError.sendFailed("WebSocket connection lost before setup completed")
            }
        }
        return isConnected
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        guard isReceiving, let ws = webSocketTask else { return }

        ws.receive { [weak self] result in
            guard let self, self.isReceiving else { return }
            guard ws === self.webSocketTask else {
                print("[Realtime] Ignoring stale receive callback from old WebSocket")
                return
            }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.startReceiveLoop()

            case .failure(let error):
                let desc = error.localizedDescription
                // #region agent log
                _dbgWS("RSM:recvError", "H2/H5: receive loop failure", ["error": desc, "nsError": "\(error)", "isConnected": self.isConnected])
                // #endregion
                print("[Realtime] Receive error: \(desc)")
                self.lastCloseInfo = self.lastCloseInfo ?? "receiveError: \(desc)"
                if !self.isConnected {
                    self.earlyCloseReason = self.earlyCloseReason ?? desc
                }
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

        // Parse Gemini server message into our event model
        let events: [RealtimeServerEvent] = RealtimeServerEvent.parse(from: data)

        if events.isEmpty {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            print("[Realtime] Unparseable event: \(preview)")
            return
        }

        for event in events {
            switch event {
            case .sessionCreated:
                isConnected = true
                print("[Realtime] Gemini setupComplete received")
            case .sessionResumptionUpdate(let token):
                lastResumptionToken = token
                print("[Realtime] Session resumption token updated (\(token.prefix(12))...)")
            case .error(let message, let code):
                print("[Realtime] API error [\(code ?? "?")]: \(message)")
                connectionError = message
            case .responseAudioDelta:
                break // Don't log audio deltas (too noisy)
            case .responseDone:
                print("[Realtime] Event: turnComplete")
            case .responseFunctionCallArgumentsDone(_, let name, _):
                print("[Realtime] Event: toolCall → \(name)")
            default:
                print("[Realtime] Event: \(event)")
            }

            eventPublisher.send(event)
        }
    }

    // MARK: - Tool Response Helpers

    private func buildToolResponse(id: String, name: String, result: [String: Any]) -> [String: Any] {
        [
            "toolResponse": [
                "functionResponses": [
                    [
                        "id": id,
                        "name": name,
                        "response": ["result": result]
                    ] as [String: Any]
                ]
            ]
        ]
    }

    // MARK: - Keepalive Pings

    private func startPingTimer() {
        stopPingTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 8, repeating: 8)
        timer.setEventHandler { [weak self] in
            self?.sendPing()
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func sendPing() {
        guard let ws = webSocketTask else { return }
        ws.sendPing { [weak self] error in
            guard let self, ws === self.webSocketTask else { return }
            if let error {
                print("[Realtime] Ping failed: \(error.localizedDescription)")
                self.handleDisconnect(source: "ping_failed")
            }
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect(source: String) {
        stopPingTimer()
        isConnected = false

        guard !intentionalDisconnect else {
            print("[Realtime] Intentional disconnect — not reconnecting (source: \(source))")
            return
        }

        if autoReconnectDisabled {
            guard !hasEmittedDisconnectEvent else { return }
            hasEmittedDisconnectEvent = true
            let detail = lastCloseInfo ?? "unknown"
            print("[Realtime] Auto-reconnect disabled — coordinator will handle reconnection (source: \(source), detail: \(detail))")
            isReceiving = false
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            eventPublisher.send(.error(message: "WebSocket disconnected [\(source)] \(detail)", code: "websocket_disconnected"))
            return
        }

        guard !isReconnecting else {
            print("[Realtime] Already reconnecting — ignoring duplicate disconnect (source: \(source))")
            return
        }

        guard reconnectAttempts < maxReconnectAttempts else {
            print("[Realtime] Max reconnect attempts (\(maxReconnectAttempts)) reached — giving up")
            connectionError = "Connection lost. Please try again."
            isReconnecting = false
            webSocketTask = nil
            eventPublisher.send(.error(message: "Connection lost after \(maxReconnectAttempts) retries", code: "reconnect_failed"))
            return
        }

        isReconnecting = true
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 15.0)
        print("[Realtime] Reconnecting in \(delay)s (attempt \(reconnectAttempts)/\(maxReconnectAttempts), source: \(source))...")

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
                    let freshKey = try await self.fetchGeminiApiKey()
                    try await self.connectWebSocket(apiKey: freshKey)

                    if let config = self.currentSessionConfig {
                        try await self.sendSetup(config)
                    }

                    self.isReconnecting = false
                    print("[Realtime] Reconnected successfully")
                } catch {
                    print("[Realtime] Reconnection failed: \(error.localizedDescription)")
                    self.isReconnecting = false
                    self.handleDisconnect(source: "reconnect_retry")
                }
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension RealtimeSessionManager: URLSessionWebSocketDelegate {

    func urlSession(_ session: URLSession, webSocketTask task: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard task === self.webSocketTask else { return }
        // #region agent log
        _dbgWS("RSM:didOpen", "H5: WebSocket handshake succeeded", ["protocol": `protocol` ?? "none"])
        // #endregion
        print("[Realtime] WebSocket didOpen")
    }

    func urlSession(_ session: URLSession, webSocketTask task: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        let info = "code=\(closeCode.rawValue) reason=\(reasonStr)"
        // #region agent log
        _dbgWS("RSM:didClose", "H2/H5: WebSocket closed by server", ["closeCode": closeCode.rawValue, "reason": String(reasonStr.prefix(300))])
        // #endregion
        print("[Realtime] WebSocket didClose: \(info)")
        guard task === self.webSocketTask else {
            print("[Realtime] Ignoring close from stale WebSocket")
            return
        }
        lastCloseInfo = info
        if !isConnected {
            earlyCloseReason = info
        }
        // 1007 "Request contains an invalid argument." right after setup
        // means something in our setup payload is poisoned — typically a
        // resumption handle from a session the server already discarded,
        // or a cachedContent reference that no longer exists. Retrying
        // with the same state fails forever (observed 2026-06-11: every
        // reconnect rejected, game permanently frozen). Drop both so the
        // coordinator's next attempt connects fresh from its checkpoint.
        if closeCode == .invalidFramePayloadData
            || reasonStr.localizedCaseInsensitiveContains("invalid argument") {
            print("[Realtime] Setup rejected (invalid argument) — clearing resumption token and cached content for a fresh reconnect")
            // #region agent log
            _dbgWS("RSM:didClose", "H2/H5: clearing poisoned resumption state after 1007", [:])
            // #endregion
            lastResumptionToken = nil
            if let key = lastApiKey {
                GeminiCacheService.shared.invalidate(apiKey: key)
            }
        }
        handleDisconnect(source: "didClose:\(closeCode.rawValue)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === webSocketTask else { return }
        if let error {
            let info = "taskError: \(error.localizedDescription)"
            // #region agent log
            _dbgWS("RSM:taskError", "H5: URLSession task error", ["error": error.localizedDescription, "httpStatus": (task.response as? HTTPURLResponse)?.statusCode ?? 0])
            // #endregion
            print("[Realtime] WebSocket task error: \(info)")
            lastCloseInfo = info
            if !isConnected {
                earlyCloseReason = info
            }
        }
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
