import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        print("[SceneDelegate] iPhone scene connecting")
        guard let windowScene = scene as? UIWindowScene else {
            print("[SceneDelegate] Failed to cast to UIWindowScene")
            return
        }

        print("[SceneDelegate] Creating IPhoneViewController")
        window = UIWindow(windowScene: windowScene)
        let viewController = IPhoneViewController()
        let navigationController = UINavigationController(rootViewController: viewController)
        window?.rootViewController = navigationController
        window?.makeKeyAndVisible()
        print("[SceneDelegate] Window is now visible")
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        print("[SceneDelegate] Received URL: \(url)")
        AuthService.shared.handleGoogleCallback(url: url)
    }
}
