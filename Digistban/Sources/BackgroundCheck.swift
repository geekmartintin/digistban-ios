import BackgroundTasks
import Foundation
import Security
import UIKit
import WebKit

/// New messages while the app is closed. Push notifications need a paid Apple
/// developer account, so the app asks iOS to wake it from time to time
/// (Background App Refresh), checks the unread conversations and shows local
/// notifications. iOS decides when: often every 15 to 60 minutes for an app in
/// regular use, less when the battery is low, never if refresh is turned off.
enum BackgroundCheck {
    static let identifier = "com.digistban.app.refresh"
    private static let api = URL(string: "https://digistban.com/help/api/chat/conversations")!

    private enum Keys {
        static let signedIn = "signedIn"
        static let language = "language"
        static let strings = "notificationStrings"
        static let notified = "notifiedConversations"
    }

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            BackgroundCheck.handle(refresh)
        }
    }

    static func schedule() {
        guard UserDefaults.standard.bool(forKey: Keys.signedIn) else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// "available", "denied" (turned off by the user) or "restricted".
    static func availability() -> String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: return "available"
        case .denied: return "denied"
        default: return "restricted"
        }
    }

    /// From the web app: who is signed in, in which language, and the texts of notifications.
    static func updateSession(signedIn: Bool, language: String?, strings: [String: String]?) {
        let defaults = UserDefaults.standard
        defaults.set(signedIn, forKey: Keys.signedIn)
        if let language = language { defaults.set(language, forKey: Keys.language) }
        if let strings = strings { defaults.set(strings, forKey: Keys.strings) }
        if signedIn {
            saveSession()
            schedule()
        } else {
            Keychain.delete()
            defaults.removeObject(forKey: Keys.notified)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            Notifications.setBadge(0)
        }
    }

    /// Keeps a copy of the session cookie in the Keychain: in the background
    /// the web view's cookie store may not be available.
    static func saveSession() {
        guard UserDefaults.standard.bool(forKey: Keys.signedIn) else { return }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let mine = cookies.filter { WebViewController.isAppHost($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) && $0.path.hasPrefix("/help") }
            if let header = HTTPCookie.requestHeaderFields(with: mine)["Cookie"], !header.isEmpty {
                Keychain.save(header)
            }
        }
    }

    /// The web app showed this message itself (app still alive in the background).
    static func markNotified(_ conversation: String, at: String) {
        var notified = UserDefaults.standard.dictionary(forKey: Keys.notified) as? [String: String] ?? [:]
        notified[conversation] = at
        UserDefaults.standard.set(notified, forKey: Keys.notified)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let once = Once()
        let finish: (Bool) -> Void = { success in
            DispatchQueue.main.async {
                once.run { task.setTaskCompleted(success: success) }
            }
        }
        task.expirationHandler = { finish(false) }
        check(finish)
    }

    /// Asks the server for the conversations and notifies new unread messages once each.
    static func check(_ done: @escaping (Bool) -> Void) {
        guard UserDefaults.standard.bool(forKey: Keys.signedIn), let cookie = Keychain.read() else {
            done(false)
            return
        }
        var request = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let language = UserDefaults.standard.string(forKey: Keys.language) {
            request.setValue(language, forHTTPHeaderField: "X-Digistban-Lang")
        }
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                // Signed out elsewhere or session expired: stop until the next sign-in.
                DispatchQueue.main.async { BackgroundCheck.updateSession(signedIn: false, language: nil, strings: nil) }
                done(false)
                return
            }
            guard status == 200, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let conversations = json["conversations"] as? [[String: Any]] else {
                done(false)
                return
            }
            DispatchQueue.main.async {
                BackgroundCheck.notify(conversations)
                done(true)
            }
        }.resume()
    }

    private static func number(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func notify(_ conversations: [[String: Any]]) {
        let defaults = UserDefaults.standard
        var notified = defaults.dictionary(forKey: Keys.notified) as? [String: String] ?? [:]
        let strings = defaults.dictionary(forKey: Keys.strings) as? [String: String] ?? [:]
        var total = 0
        for conversation in conversations {
            guard let id = conversation["id"] as? String else { continue }
            let unread = number(conversation["unread"])
            total += unread
            guard unread > 0, let at = conversation["lastMessageAt"] as? String, notified[id] != at else { continue }
            notified[id] = at

            var title = strings["newMessage"] ?? "Digistban"
            if let name = conversation["otherDisplayName"] as? String, !name.isEmpty {
                title = name
            } else if let username = conversation["otherUsername"] as? String, !username.isEmpty {
                title = "@" + username
            }
            var body: String
            switch conversation["lastKind"] as? String {
            case "voice": body = strings["voice"] ?? "Message vocal"
            case "transfer": body = strings["transfer"] ?? "Fichiers"
            case "call": body = strings["call"] ?? "Appel manqué"
            default: body = (conversation["lastBody"] as? String) ?? strings["newMessage"] ?? ""
            }
            if unread > 1, let more = strings["unread"] {
                body = more.replacingOccurrences(of: "{count}", with: String(unread)) + " · " + body
            }
            Notifications.show(id: "conversation-\(id)", title: title, body: body, path: "/messages/\(id)", thread: id)
        }
        defaults.set(notified, forKey: Keys.notified)
        Notifications.setBadge(total)
    }
}

/// Runs its body the first time only.
final class Once {
    private var done = false

    func run(_ body: () -> Void) {
        guard !done else { return }
        done = true
        body()
    }
}

/// The session cookie, readable in the background once the iPhone was unlocked after starting.
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.digistban.app",
        kSecAttrAccount as String: "session",
    ]

    static func save(_ value: String) {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = query
            item.merge(update) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func read() -> String? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
