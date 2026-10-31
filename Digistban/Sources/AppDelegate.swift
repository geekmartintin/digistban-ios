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
        Uploader.shared.restore()
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
        if let shortcut = connectionOptions.shortcutItem {
            controller.perform(shortcut: shortcut.type)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        WebViewController.shared.perform(shortcut: shortcutItem.type)
        completionHandler(true)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url {
            WebViewController.shared.open(deepLink: url)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // The page takes over again (its own connection, sound and microphone),
        // including a call just answered on the iPhone's call screen.
        KeepAlive.shared.stop()
        RealtimeListener.shared.stop()
        NativeCalls.shared.takeOver()
        WebViewController.shared.didReturnToForeground()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Started while the app is still in front: iOS may refuse to start audio from the background.
        // Not during a call: the page's audio session must stay as it is. A transfer being
        // sent keeps the app running too, even if "stay reachable" is off.
        guard BackgroundCheck.signedIn, KeepAlive.enabled || Uploader.shared.isBusy, !Bridge.inCall else { return }
        KeepAlive.shared.start()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        KeepAlive.shared.stop()
        WebViewController.shared.collectSharedFiles()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        BackgroundCheck.schedule()
        guard BackgroundCheck.signedIn else { return }
        Diagnostics.note(KeepAlive.enabled ? (Bridge.inCall ? "background-in-call" : "background") : "background-reachable-off")
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
