import Foundation
import Combine

enum LiveProvider: String {
    case gemini
    case grok

    static var selected: LiveProvider {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "liveProvider") == LiveProvider.grok.rawValue {
            return .grok
        }
        #endif
        return .gemini
    }
}

protocol LiveSessionManaging: AnyObject {
    var isConnected: Bool { get }
    var connectionError: String? { get }
    var isConnectedPublisher: AnyPublisher<Bool, Never> { get }
    var eventPublisher: PassthroughSubject<RealtimeServerEvent, Never> { get }
    var autoReconnectDisabled: Bool { get set }
    var lastCloseInfo: String? { get }
    var lastResumptionToken: String? { get }
    var hasPendingResults: Bool { get }

    func connect(sessionConfig: SessionConfig) async throws
    func send(_ event: RealtimeClientEvent) async throws
    func sendAudio(_ base64Audio: String) async throws
    func disconnect(preserveResumptionToken: Bool)
    func submitFunctionResult(
        callId: String,
        result: [String: Any],
        name: String
    ) async throws
    func queueFunctionResult(
        callId: String,
        result: [String: Any],
        name: String
    ) async throws
    func flushPendingResults(instructions: String?) async throws
}

extension LiveSessionManaging {
    func disconnect() {
        disconnect(preserveResumptionToken: false)
    }

    func flushPendingResults() async throws {
        try await flushPendingResults(instructions: nil)
    }
}
