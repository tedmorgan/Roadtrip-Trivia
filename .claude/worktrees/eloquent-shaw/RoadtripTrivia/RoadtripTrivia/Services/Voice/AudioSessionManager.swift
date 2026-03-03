import Foundation
import AVFoundation

/// Manages AVAudioSession for CarPlay. Handles:
/// - Session activation/deactivation per iOS 26.4 audio discipline rules
/// - Interruption handling (calls, Siri, nav prompts)
/// - Audio ducking for thinking stinger
/// Per iOS 26.4: only hold audio session while voice features are actively in use.
class AudioSessionManager: ObservableObject {

    static let shared = AudioSessionManager()

    @Published private(set) var isActive = false
    @Published private(set) var isInterrupted = false

    /// Called when an interruption occurs — the game coordinator should pause.
    var onInterruption: (() -> Void)?
    /// Called when an interruption ends — the game coordinator should offer resume.
    var onInterruptionEnd: (() -> Void)?

    private var thinkingPlayer: AVAudioPlayer?
    private let session = AVAudioSession.sharedInstance()

    private init() {}

    // MARK: - Configuration

    /// Initial setup — call once at app launch.
    func configureForCarPlay() {
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
            )
        } catch {
            print("[AudioSessionManager] Failed to configure: \(error)")
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
    }

    // MARK: - Activate / Deactivate

    /// Activate before speaking or listening. Per iOS 26.4: only hold while voice is active.
    func activateForSpeech() {
        guard !isActive else { return }
        do {
            try session.setActive(true, options: [])
            isActive = true
        } catch {
            print("[AudioSessionManager] Activation failed: \(error)")
        }
    }

    /// Release audio session between questions/rounds so music/radio can resume.
    func deactivate() {
        guard isActive else { return }
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            isActive = false
        } catch {
            print("[AudioSessionManager] Deactivation failed: \(error)")
        }
    }

    // MARK: - Thinking Stinger (GAME-008)

    func playThinkingStinger() {
        // Play bundled game-show thinking music during grading
        guard let url = Bundle.main.url(forResource: "thinking_stinger", withExtension: "mp3") else { return }
        do {
            thinkingPlayer = try AVAudioPlayer(contentsOf: url)
            thinkingPlayer?.numberOfLoops = -1 // loop until stopped
            thinkingPlayer?.volume = 0.3 // duck relative to TTS
            thinkingPlayer?.play()
        } catch {
            print("[AudioSessionManager] Stinger playback failed: \(error)")
        }
    }

    func stopThinkingStinger() {
        thinkingPlayer?.stop()
        thinkingPlayer = nil
    }

    // MARK: - Interruption Handling

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            isInterrupted = true
            isActive = false
            onInterruption?()

        case .ended:
            isInterrupted = false
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    activateForSpeech()
                }
            }
            onInterruptionEnd?()

        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        if reason == .oldDeviceUnavailable {
            // CarPlay disconnected or Bluetooth dropped
            isInterrupted = true
            onInterruption?()
        }
    }
}
