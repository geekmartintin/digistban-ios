import AppIntents
import Foundation

/// Buttons of the Live Activity (Lock Screen, Dynamic Island): pause, resume or
/// cancel a transfer. iOS runs them in the app, waking it in the background if
/// needed; the widget extension only draws the buttons.
@available(iOS 17.0, *)
struct TransferControlIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Digistban"

    @Parameter(title: "Job")
    var job: String

    @Parameter(title: "Action")
    var action: String

    init() {}

    init(job: String, action: String) {
        self.job = job
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        #if DIGISTBAN_APP
        await MainActor.run { TransferControl.handle(job: job, action: action) }
        #endif
        return .result()
    }
}

/// "Share" once a transfer is over: opens the app on the share sheet of the
/// downloaded file, or on the sent transfer and its link.
@available(iOS 17.0, *)
struct TransferShareIntent: AppIntent {
    static var title: LocalizedStringResource = "Digistban"
    static var openAppWhenRun = true

    @Parameter(title: "Link")
    var link: String

    init() {}

    init(link: String) {
        self.link = link
    }

    func perform() async throws -> some IntentResult {
        #if DIGISTBAN_APP
        await MainActor.run { TransferControl.share(link: link) }
        #endif
        return .result()
    }
}
