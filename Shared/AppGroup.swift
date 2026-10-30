import Foundation

/// The folder shared by the app and its share extension (App Group). When the
/// app is signed again (Sideloadly, AltStore), the group may be renamed for the
/// signing account: the real name is read from the provisioning profile.
enum AppGroup {
    static let defaultIdentifier = "group.com.digistban.app"

    static let identifier: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>", range: start.lowerBound..<text.endIndex),
              let plistData = String(text[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String],
              let first = groups.first(where: { $0.hasPrefix(defaultIdentifier) }) ?? groups.first else {
            return defaultIdentifier
        }
        return first
    }()

    /// nil when the signature has no App Group (the share extension then explains it).
    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Files shared from other apps, waiting for the app: Inbox/<id>/<file name>.
    static var inbox: URL? {
        container?.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Keeps a name usable as a file name.
    static func safeName(_ suggested: String) -> String {
        let cleaned = suggested
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\0"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Digistban" : cleaned
    }
}
