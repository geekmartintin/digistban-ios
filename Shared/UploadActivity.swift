import ActivityKit
import Foundation

/// A transfer being sent, or a file being downloaded, on the Lock Screen and
/// in the Dynamic Island (Live Activity). Shared by the app, which updates it, and the widget extension,
/// which draws it. Texts arrive ready to show, in the account's language.
@available(iOS 16.1, *)
struct UploadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 0 to 1.
        var fraction: Double
        /// "preparing", "uploading", "paused", "finalizing", "completed", "failed" or "cancelled".
        var status: String
        /// e.g. "Envoi en cours".
        var label: String
        /// e.g. "1,2 Go sur 3,4 Go".
        var detail: String
        /// Opened when the activity is tapped (digistban://transfers/…).
        var link: String
        /// Replaces the title once known (the name of a downloaded file).
        var title: String?
    }

    var jobId: String
    var title: String
    var fileCount: Int
    /// "upload" or "download".
    var kind: String = "upload"
}
