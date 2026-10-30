import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private let notificationRouter = NotificationRouter()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Set before launch ends so a tap on a notification that opened the app is not lost.
        UNUserNotificationCenter.current().delegate = notificationRouter
        let decline = UNNotificationAction(identifier: "decline", title: NSLocalizedString("call.decline", comment: ""), options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "call", actions: [decline], intentIdentifiers: [], options: []),
        ])
        BackgroundCheck.register()
        Downloads.cleanUp()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let controller = WebViewController.shared
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        if let url = connectionOptions.urlContexts.first?.url {
            controller.open(deepLink: url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url {
            WebViewController.shared.open(deepLink: url)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // The page takes over again (its own connection, sound and microphone).
        RealtimeListener.shared.stop()
        KeepAlive.shared.stop()
        WebViewController.shared.didReturnToForeground()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        BackgroundCheck.schedule()
        guard BackgroundCheck.signedIn else { return }
        // Not during a call: the page's audio session must stay as it is.
        if KeepAlive.enabled && !Bridge.inCall { KeepAlive.shared.start() }
        RealtimeListener.shared.start()
    }
}

/// Notifications shown while the app is open stay silent (the web app shows its
/// own banners); a tap on one opens the matching screen.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let path = info["path"] as? String
        let callId = info["callId"] as? String
        let declined = response.actionIdentifier == "decline"
        DispatchQueue.main.async {
            if declined, let callId = callId {
                RealtimeListener.shared.decline(callId)
            } else if let path = path {
                WebViewController.shared.navigate(to: path)
            }
            completionHandler()
        }
    }
}
