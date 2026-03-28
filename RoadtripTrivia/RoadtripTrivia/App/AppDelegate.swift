import UIKit
import CarPlay
import Network
import AVFoundation
import Combine

// MARK: - Connection Monitor

final class ConnectionMonitor: ObservableObject {

    static let shared = ConnectionMonitor()

    @Published private(set) var isConnected = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ConnectionMonitor", qos: .utility)
    private var synthesizer = AVSpeechSynthesizer()

    private init() {}

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    private func handlePathUpdate(_ path: NWPath) {
        let wasConnected = isConnected
        isConnected = (path.status == .satisfied)

        if !isConnected && wasConnected {
            speakOffline("Your connection has been lost. The game is paused. It will resume automatically when your connection comes back.")
        }

        if isConnected && !wasConnected {
            speakOffline("Connection restored. Let's keep playing!")
        }
    }

    func speakOffline(_ message: String) {
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer.speak(utterance)
        print("[ConnectionMonitor] Spoke offline alert: \(message)")
    }
}

// MARK: - App Delegate

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        print("[AppDelegate] App launched")
        AudioSessionManager.shared.configureForCarPlay()
        ConnectionMonitor.shared.start()

        // Initialize StoreKit 2 transaction listener early so purchases
        // made outside the app (renewals, Ask-to-Buy) are processed.
        Task { @MainActor in
            _ = StoreService.shared
        }

        return true
    }

    // MARK: - UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(
                name: "CarPlay Configuration",
                sessionRole: connectingSceneSession.role
            )
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }

        let config = UISceneConfiguration(
            name: "iPhone Configuration",
            sessionRole: connectingSceneSession.role
        )
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {}
}
