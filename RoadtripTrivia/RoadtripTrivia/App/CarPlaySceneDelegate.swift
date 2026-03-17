import UIKit
import CarPlay
import MediaPlayer

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    var interfaceController: CPInterfaceController?
    var carPlayCoordinator: CarPlayCoordinator?

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        print("[CarPlaySceneDelegate] CarPlay connected")
        self.interfaceController = interfaceController

        carPlayCoordinator = CarPlayCoordinator(interfaceController: interfaceController)
        carPlayCoordinator?.start()
        setupRemoteCommandCenter()
        print("[CarPlaySceneDelegate] Coordinator started")
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        print("[CarPlaySceneDelegate] CarPlay disconnected")
        carPlayCoordinator?.handleDisconnect()
        carPlayCoordinator = nil
        self.interfaceController = nil
        tearDownRemoteCommandCenter()
    }

    // MARK: - Remote Command Center (play/pause from CarPlay hardware button)

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            print("[CarPlay] Play button pressed")
            self?.carPlayCoordinator?.handlePlayPause(paused: false)
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            print("[CarPlay] Pause button pressed")
            self?.carPlayCoordinator?.handlePlayPause(paused: true)
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            print("[CarPlay] Toggle play/pause button pressed")
            self?.carPlayCoordinator?.togglePlayPause()
            return .success
        }
    }

    private func tearDownRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
    }
}

