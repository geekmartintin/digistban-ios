import UIKit
import UserNotifications
import WebKit

/// Messages from the web app (`window.webkit.messageHandlers.digistban`), see
/// frontend/src/lib/native.ts for the other side.
final class Bridge: NSObject, WKScriptMessageHandler {
    weak var controller: WebViewController?
    /// A call is on in the page (it asked to keep the screen on).
    static var inCall = false

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }

    /// Runs before the page's own scripts: tells the web app it lives in the iPhone app.
    static func startScript() -> String {
        let info: [String: Any] = [
            "platform": "ios",
            "version": version,
            "build": build,
            "notifications": UserDefaults.standard.string(forKey: Notifications.statusKey) ?? "prompt",
            "backgroundRefresh": BackgroundCheck.availability(),
            "microphone": MediaPermissions.status(.audio),
            "camera": MediaPermissions.status(.video),
            "reachable": KeepAlive.enabled,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.DigistbanNative = \(json);"
    }

    /// An app does not zoom: no pinch zoom of the interface, no zoom on focusing a field.
    static let viewportScript = """
    (function () {
      var meta = document.querySelector('meta[name=viewport]');
      if (!meta) { meta = document.createElement('meta'); meta.name = 'viewport'; document.head.appendChild(meta); }
      var content = meta.getAttribute('content') || 'width=device-width, initial-scale=1, viewport-fit=cover';
      if (content.indexOf('maximum-scale') < 0) content += ', maximum-scale=1, user-scalable=no';
      meta.setAttribute('content', content);
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              WebViewController.isAppHost(message.frameInfo.securityOrigin.host),
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            controller?.webAppReady()
        case "haptic":
            Haptics.play(body["style"] as? String)
        case "badge":
            Notifications.setBadge((body["count"] as? Int) ?? 0)
        case "theme":
            let background = (body["background"] as? String).flatMap { UIColor(hex: $0) }
            controller?.applyTheme(dark: (body["dark"] as? Bool) ?? true, background: background)
        case "keepAwake":
            // Sent while a call is on: the screen stays on.
            let on = (body["on"] as? Bool) ?? false
            UIApplication.shared.isIdleTimerDisabled = on
            Bridge.inCall = on
        case "session":
            BackgroundCheck.updateSession(
                signedIn: (body["signedIn"] as? Bool) ?? false,
                userId: body["userId"] as? String,
                language: body["lang"] as? String,
                strings: body["strings"] as? [String: String]
            )
        case "notify":
            // Only when the app is not on screen (the page shows its own banners otherwise),
            // and not twice when the app's own connection already notified it.
            guard UIApplication.shared.applicationState != .active, !RealtimeListener.shared.connected,
                  let title = body["title"] as? String else { return }
            let thread = body["thread"] as? String
            Notifications.show(
                id: thread.map { "conversation-\($0)" } ?? UUID().uuidString,
                title: title,
                body: (body["body"] as? String) ?? "",
                path: body["path"] as? String,
                thread: thread
            )
            if let thread = thread, let at = body["at"] as? String { BackgroundCheck.markNotified(thread, at: at) }
        case "requestNotifications":
            Notifications.request { [weak self] _ in self?.controller?.sendStatus() }
        case "requestMedia":
            MediaPermissions.request { [weak self] in self?.controller?.sendStatus() }
        case "setReachable":
            UserDefaults.standard.set((body["on"] as? Bool) ?? true, forKey: KeepAlive.settingKey)
            controller?.sendStatus()
        case "openSettings":
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        default:
            break
        }
    }
}

enum Haptics {
    static func play(_ style: String?) {
        switch style {
        case "selection": UISelectionFeedbackGenerator().selectionChanged()
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "soft": UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case "rigid": UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

enum Notifications {
    static let statusKey = "notificationStatus"

    /// "granted", "denied" or "prompt" (not asked yet), on the main queue.
    static func status(_ done: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let value: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: value = "granted"
            case .denied: value = "denied"
            default: value = "prompt"
            }
            DispatchQueue.main.async {
                UserDefaults.standard.set(value, forKey: Notifications.statusKey)
                done(value)
            }
        }
    }

    static func request(_ done: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            Notifications.status(done)
        }
    }

    static func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { _ in }
    }

    /// Shows a notification now. The same `id` replaces the previous one (one per conversation).
    static func show(id: String, title: String, body: String, path: String?, thread: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let thread = thread { content.threadIdentifier = thread }
        if let path = path { content.userInfo = ["path": path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
    }
}

extension UIColor {
    /// "#rrggbb"
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
