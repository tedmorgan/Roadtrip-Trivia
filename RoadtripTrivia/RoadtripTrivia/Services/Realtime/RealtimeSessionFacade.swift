import Foundation
import Combine

/// Stable app-facing session facade. Gemini is the production default while
/// the Grok implementation remains available as a one-release debug fallback.
final class RealtimeSessionManager: ObservableObject, LiveSessionManaging {
    @Published private(set) var isConnected = false
    @Published private(set) var connectionError: String?

    var isConnectedPublisher: AnyPublisher<Bool, Never> {
        $isConnected.eraseToAnyPublisher()
    }
    let eventPublisher = PassthroughSubject<RealtimeServerEvent, Never>()

    private let provider: LiveProvider
    private let implementation: LiveSessionManaging
    private var cancellables = Set<AnyCancellable>()

    init(provider: LiveProvider = .selected) {
        self.provider = provider
        switch provider {
        case .gemini:
            implementation = GeminiLiveSessionManager()
        case .grok:
            implementation = GrokLiveSessionManager()
        }

        implementation.isConnectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.isConnected = connected
                self?.connectionError = self?.implementation.connectionError
            }
            .store(in: &cancellables)

        implementation.eventPublisher
            .sink { [weak self] event in
                self?.connectionError = self?.implementation.connectionError
                self?.eventPublisher.send(event)
            }
            .store(in: &cancellables)
    }

    var autoReconnectDisabled: Bool {
        get { implementation.autoReconnectDisabled }
        set { implementation.autoReconnectDisabled = newValue }
    }

    var lastCloseInfo: String? { implementation.lastCloseInfo }
    var lastResumptionToken: String? { implementation.lastResumptionToken }
    var hasPendingResults: Bool { implementation.hasPendingResults }

    func connect(sessionConfig: SessionConfig) async throws {
        let providerConfig: SessionConfig
        switch provider {
        case .gemini:
            providerConfig = SessionConfig(
                instructions: sessionConfig.instructions,
                voice: Self.geminiVoice(from: sessionConfig.voice),
                tools: sessionConfig.tools,
                model: "gemini-3.1-flash-live-preview",
                resumptionHandle: sessionConfig.resumptionHandle
            )
        case .grok:
            providerConfig = SessionConfig(
                instructions: sessionConfig.instructions,
                voice: "sal",
                tools: sessionConfig.tools,
                model: "grok-voice-think-fast-2.0",
                resumptionHandle: sessionConfig.resumptionHandle
            )
        }
        try await implementation.connect(sessionConfig: providerConfig)
    }

    func send(_ event: RealtimeClientEvent) async throws {
        try await implementation.send(event)
    }

    func sendAudio(_ base64Audio: String) async throws {
        try await implementation.sendAudio(base64Audio)
    }

    func disconnect(preserveResumptionToken: Bool = false) {
        implementation.disconnect(preserveResumptionToken: preserveResumptionToken)
    }

    func submitFunctionResult(
        callId: String,
        result: [String: Any],
        name: String = ""
    ) async throws {
        try await implementation.submitFunctionResult(
            callId: callId,
            result: result,
            name: name
        )
    }

    func queueFunctionResult(
        callId: String,
        result: [String: Any],
        name: String = ""
    ) async throws {
        try await implementation.queueFunctionResult(
            callId: callId,
            result: result,
            name: name
        )
    }

    func flushPendingResults(instructions: String? = nil) async throws {
        try await implementation.flushPendingResults(instructions: instructions)
    }

    private static func geminiVoice(from requested: String) -> String {
        let supported = ["Orus", "Sadachbia", "Puck", "Fenrir", "Laomedeia"]
        return supported.first {
            $0.caseInsensitiveCompare(requested) == .orderedSame
        } ?? "Orus"
    }
}
