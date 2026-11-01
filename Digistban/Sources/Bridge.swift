import CoreHaptics
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
            "tabBar": GlassTabs.available,
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
        case "tabs":
            controller?.glassTabs?.apply(
                visible: (body["visible"] as? Bool) ?? false,
                active: body["active"] as? Int,
                unread: (body["unread"] as? Int) ?? 0,
                initials: (body["initials"] as? String) ?? "",
                labels: (body["labels"] as? [String]) ?? []
            )
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
        case "diag":
            if let event = body["event"] as? String { Diagnostics.note("web-" + String(event.prefix(60))) }
        case "pickFiles":
            controller?.pickFiles(source: body["source"] as? String)
        case "scanQR":
            controller?.presentScanner()
        case "upload":
            if let job = body["job"] as? [String: Any] { Uploader.shared.start(job) }
        case "uploadControl":
            if let id = body["id"] as? String, let action = body["action"] as? String { Uploader.shared.control(id, action: action) }
        case "requestMedia":
            MediaPermissions.request { [weak self] in self?.controller?.sendStatus() }
        case "setReachable":
            UserDefaults.standard.set((body["on"] as? Bool) ?? true, forKey: KeepAlive.settingKey)
            controller?.sendStatus()
        case "openInSafari":
            // The real Safari (not an in-app view): it can add the web app to the Home Screen.
            if let text = body["url"] as? String, let url = URL(string: text), WebViewController.isAppURL(url) {
                UIApplication.shared.open(url)
            }
        case "openSettings":
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case "openExternal":
            if let text = body["url"] as? String, let url = URL(string: text) { controller?.openPayment(url) }
        case "closeExternal":
            controller?.closePayment()
        default:
            break
        }
    }
}

/// Taps felt in the hand, at full strength: Core Haptics patterns (intensity 1,
/// the sharpness gives each its character), the system generators otherwise.
enum Haptics {
    private static var engine: CHHapticEngine?
    private static var supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// (start, intensity, sharpness, duration: 0 for a tap)
    private static func events(_ style: String?) -> [(TimeInterval, Float, Float, TimeInterval)] {
        switch style {
        case "selection": return [(0, 0.9, 0.9, 0)]
        case "soft": return [(0, 1, 0.15, 0)]
        case "rigid": return [(0, 1, 1, 0)]
        case "medium": return [(0, 1, 0.5, 0)]
        case "heavy": return [(0, 1, 0.3, 0), (0, 1, 0.2, 0.08)]
        case "success": return [(0, 1, 0.45, 0), (0.12, 1, 0.9, 0)]
        case "warning": return [(0, 1, 0.6, 0), (0.15, 1, 0.6, 0)]
        case "error": return [(0, 1, 0.9, 0), (0.08, 1, 0.9, 0), (0.16, 1, 0.9, 0)]
        // A call ringing on screen: three long, deep pulses.
        case "ring": return [(0, 1, 0.35, 0.24), (0.4, 1, 0.35, 0.24), (0.8, 1, 0.35, 0.24)]
        default: return [(0, 1, 0.7, 0)]
        }
    }

    private static func ready() -> CHHapticEngine? {
        guard supported else { return nil }
        if let engine = engine { return engine }
        do {
            let created = try CHHapticEngine()
            created.playsHapticsOnly = true
            created.isAutoShutdownEnabled = true
            created.resetHandler = { [weak created] in try? created?.start() }
            engine = created
            return created
        } catch {
            supported = false
            return nil
        }
    }

    static func play(_ style: String?) {
        // Haptics only play while the app is on screen.
        guard UIApplication.shared.applicationState != .background else { return }
        guard let engine = ready() else { return fallback(style) }
        let pattern = events(style).map { start, intensity, sharpness, duration -> CHHapticEvent in
            let parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ]
            return duration > 0
                ? CHHapticEvent(eventType: .hapticContinuous, parameters: parameters, relativeTime: start, duration: duration)
                : CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: start)
        }
        do {
            try engine.start()
            try engine.makePlayer(with: CHHapticPattern(events: pattern, parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback(style)
        }
    }

    private static func fallback(_ style: String?) {
        switch style {
        case "selection": UISelectionFeedbackGenerator().selectionChanged()
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "soft": UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 1)
        case "rigid", "light", nil: UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 1)
        default: UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
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
    static func show(id: String, title: String, body: String, path: String?, thread: String?, extra: [String: Any] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let thread = thread { content.threadIdentifier = thread }
        var info = extra
        if let path = path { info["path"] = path }
        content.userInfo = info
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
