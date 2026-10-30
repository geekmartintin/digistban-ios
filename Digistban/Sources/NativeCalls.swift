import CallKit
import UIKit

/// The iPhone's own call screen (CallKit, as for WhatsApp): full screen on the
/// lock screen, a banner with Accept / Decline otherwise. It only rings: once
/// the call is answered the app opens and the page connects it (WebRTC lives
/// in the page), then this native call is closed.
final class NativeCalls: NSObject, CXProviderDelegate {
    static let shared = NativeCalls()

    private struct Call {
        let id: String
        let conversation: String
        let video: Bool
    }

    private let provider: CXProvider
    private var calls: [UUID: Call] = [:]
    /// Answered on the call screen, waiting for the page to connect it.
    private var answered: Call?

    override init() {
        let configuration = CXProviderConfiguration()
        // A video call brings the app to the front when answered: needed for the page to connect it.
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        configuration.ringtoneSound = "ring.wav"
        configuration.iconTemplateImageData = UIImage(named: "CallIcon")?.pngData()
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    private func uuid(of id: String) -> UUID? {
        calls.first { $0.value.id == id }?.key
    }

    /// Shows the incoming call. `failed` runs when iOS refuses it (Focus, another call…).
    func reportIncoming(id: String, conversation: String, name: String, video: Bool, failed: @escaping () -> Void) {
        guard uuid(of: id) == nil else { return }
        let key = UUID(uuidString: id) ?? UUID()
        calls[key] = Call(id: id, conversation: conversation, video: video)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: key, update: update) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                self?.calls[key] = nil
                failed()
            }
        }
    }

    /// The call stopped ringing elsewhere (caller hung up, answered on another device, no answer).
    func end(_ id: String, reason: CXCallEndedReason) {
        guard let key = uuid(of: id) else { return }
        calls[key] = nil
        if answered?.id == id { answered = nil }
        provider.reportCall(with: key, endedAt: nil, reason: reason)
    }

    /// The app is on screen: hands a call answered on the call screen to the page.
    func takeOver() {
        let call = answered
        answered = nil
        // Close the native calls first so the page gets the microphone. A call
        // still ringing goes on ringing in the page, which shows it as well.
        for key in calls.keys {
            provider.reportCall(with: key, endedAt: nil, reason: .answeredElsewhere)
        }
        calls.removeAll()
        if let call = call {
            WebViewController.shared.answer(callId: call.id, conversation: call.conversation, video: call.video)
        }
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        calls.removeAll()
        answered = nil
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let call = calls[action.callUUID] else {
            action.fail()
            return
        }
        answered = call
        action.fulfill()
        // Already in front (answered from the banner while using the app): connect now.
        if UIApplication.shared.applicationState == .active { takeOver() }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let call = calls.removeValue(forKey: action.callUUID) {
            if answered?.id == call.id { answered = nil }
            RealtimeListener.shared.decline(call.id)
        }
        action.fulfill()
    }
}
