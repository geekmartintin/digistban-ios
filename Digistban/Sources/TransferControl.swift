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

    /// A control of the Control Centre or the Action button: the app is in front, open the right thing.
    @MainActor
    static func open(target: String) {
        Diagnostics.note("control-\(target)")
        let app = WebViewController.shared
        switch target {
        case "send":
            if let home = URL(string: "digistban://") { app.open(deepLink: home) }
            app.pickFiles(source: nil)
        case "scan":
            app.presentScanner()
        case "pay":
            if let page = URL(string: "digistban://paiements?new=1") { app.open(deepLink: page) }
        default:
            break
        }
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
