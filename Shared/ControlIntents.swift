import AppIntents
import Foundation

/// Controls of the Control Centre, the Lock Screen and the Action button (iOS 18):
/// each opens the app on one thing ("send", "scan", "pay"). The app does the work
/// (TransferControl.open); the widget extension only shows the buttons.
@available(iOS 18.0, *)
struct OpenDigistbanIntent: AppIntent {
    static var title: LocalizedStringResource = "Digistban"
    static var openAppWhenRun = true

    @Parameter(title: "Target")
    var target: String

    init() {}

    init(target: String) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        #if DIGISTBAN_APP
        await MainActor.run { TransferControl.open(target: target) }
        #endif
        return .result()
    }
}
