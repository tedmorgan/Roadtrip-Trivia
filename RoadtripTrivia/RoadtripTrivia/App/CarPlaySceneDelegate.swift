import UIKit
import CarPlay

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
    }
}
