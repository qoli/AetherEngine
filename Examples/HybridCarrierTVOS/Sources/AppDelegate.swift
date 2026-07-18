import AetherEngine
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_ENGINE_LOG_STDOUT"
        ] == "1" {
            EngineLog.handler = { line in
                print("AETHER_ENGINE \(line)")
            }
        }
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = AcceptanceViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
