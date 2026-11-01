import UIKit

/// What the Live Activity's buttons do (Shared/TransferIntents.swift), in the app.
enum TransferControl {
    @MainActor
    static func handle(job: String, action: String) {
        if job.hasPrefix("download-") {
            BackgroundDownloads.shared.control(job: job, action: action)
        } else {
            Uploader.shared.control(job, action: action)
        }
        Diagnostics.note("activity-button-\(action)")
    }

    /// The app has just come to the front: give it a moment, then share.
    @MainActor
    static func share(link: String) {
        Diagnostics.note("activity-button-share")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if link.hasPrefix("digistban://download"), let file = BackgroundDownloads.shared.lastFile {
                WebViewController.shared.shareFile(file)
            } else if let url = URL(string: link) {
                WebViewController.shared.open(deepLink: url)
            }
        }
    }
}
