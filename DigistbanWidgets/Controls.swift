import AppIntents
import SwiftUI
import WidgetKit

/// "Send files", "Scan a QR code" and "Request a payment" in the Control Centre,
/// on the Lock Screen (in place of the torch or camera) and on the Action button.
@available(iOS 18.0, *)
struct SendControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.digistban.app.control.send") {
            ControlWidgetButton(action: OpenDigistbanIntent(target: "send")) {
                Label("control.send", systemImage: "paperplane.fill")
            }
        }
        .displayName("control.send")
        .description("control.sendHint")
    }
}

@available(iOS 18.0, *)
struct ScanControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.digistban.app.control.scan") {
            ControlWidgetButton(action: OpenDigistbanIntent(target: "scan")) {
                Label("control.scan", systemImage: "qrcode.viewfinder")
            }
        }
        .displayName("control.scan")
        .description("control.scanHint")
    }
}

@available(iOS 18.0, *)
struct PaymentControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.digistban.app.control.pay") {
            ControlWidgetButton(action: OpenDigistbanIntent(target: "pay")) {
                Label("control.pay", systemImage: "eurosign.circle.fill")
            }
        }
        .displayName("control.pay")
        .description("control.payHint")
    }
}
