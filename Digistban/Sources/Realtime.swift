import AVFoundation
import CallKit
import UIKit
import UserNotifications

/// Microphone and camera, asked by the app itself so they show up in the
/// iPhone's Settings before the first call.
enum MediaPermissions {
    static func status(_ type: AVMediaType) -> String {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return "granted"
        case .denied, .restricted: return "denied"
        default: return "prompt"
        }
    }

    /// Microphone, then camera (iOS asks each once); `done` on the main queue.
    static func request(_ done: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { done() }
            }
        }
    }
}

/// Keeps the app running in the background by playing an inaudible sound, so
/// its realtime connection stays open and calls can ring: without a paid Apple
/// developer account there is no push to wake it up. Mixed with other audio,
/// so music or videos in other apps are not interrupted.
final class KeepAlive {
    static let shared = KeepAlive()
    static let settingKey = "reachable"
    private var player: AVAudioPlayer?
    private var observer: NSObjectProtocol?

    /// The user's choice in Profil (on unless turned off).
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    func start() {
        guard player == nil, let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            self.player = player
        } catch {
            return
        }
        // A phone call or an alarm pauses it: start again afterwards.
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self?.player?.play()
        }
    }

    func stop() {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let player = player else { return }
        player.stop()
        self.player = nil
        // Hand the audio back to the page (calls, voice notes) and to other apps.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// The app's own connection to the server while it is in the background
/// (Socket.IO over WebSocket): incoming calls ring as notifications, new
/// messages are notified at once. In the foreground the page has its own.
final class RealtimeListener: NSObject {
    static let shared = RealtimeListener()

    private static let endpoint = URL(string: "wss://digistban.com/help/socket.io/?EIO=4&transport=websocket")!
    private lazy var session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
    private var task: URLSessionWebSocketTask?
    private var wanted = false
    private var attempts = 0
    private var lastPacket = Date()
    private var watchdog: Timer?
    /// Calls ringing now: id -> caller name and conversation.
    private var ringing: [String: (name: String, conversation: String)] = [:]
    private(set) var connected = false

    func start() {
        guard !wanted, BackgroundCheck.signedIn else { return }
        wanted = true
        attempts = 0
        connect()
        watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            // The server pings every 25 s: silence for longer means a dead connection.
            guard let self = self, self.wanted, Date().timeIntervalSince(self.lastPacket) > 70 else { return }
            self.reconnect()
        }
    }

    func stop() {
        wanted = false
        ringing.removeAll()
        watchdog?.invalidate()
        watchdog = nil
        connected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// "Refuser" on the call notification.
    func decline(_ callId: String) {
        emit("call:decline", ["callId": callId])
        stopRinging(callId)
    }

    private func connect() {
        guard wanted, let cookie = Keychain.read() else { return }
        var request = URLRequest(url: RealtimeListener.endpoint)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://\(WebViewController.host)", forHTTPHeaderField: "Origin")
        let task = session.webSocketTask(with: request)
        self.task = task
        lastPacket = Date()
        task.resume()
        receive(task)
    }

    private func reconnect() {
        connected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard wanted else { return }
        attempts += 1
        let delay = min(60, pow(2, Double(min(attempts, 6))))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.wanted, self.task == nil else { return }
            self.connect()
        }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self, task === self.task else { return }
            switch result {
            case .failure:
                self.reconnect()
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive(task)
            }
        }
    }

    private func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    private func emit(_ event: String, _ payload: [String: Any]) {
        guard connected,
              let data = try? JSONSerialization.data(withJSONObject: [event, payload]),
              let json = String(data: data, encoding: .utf8) else { return }
        send("42" + json)
    }

    /// Engine.IO / Socket.IO v4 packets: 0 open, 2 ping, 40 connected, 44 refused, 42 event.
    private func handle(_ packet: String) {
        lastPacket = Date()
        if packet.hasPrefix("0") {
            send("40")
        } else if packet == "2" {
            send("3")
        } else if packet.hasPrefix("40") {
            connected = true
            attempts = 0
            // Not looking at the screen: the server still sends web push to other devices.
            emit("presence", ["visible": false])
        } else if packet.hasPrefix("44") {
            // Session refused (signed out or expired): wait for the next sign-in.
            stop()
        } else if packet.hasPrefix("42") {
            event(String(packet.dropFirst(2)))
        } else if packet.hasPrefix("1") {
            reconnect()
        }
    }

    private func event(_ json: String) {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let name = array.first as? String else { return }
        let payload = array.count > 1 ? array[1] as? [String: Any] : nil
        switch name {
        case "call:incoming": if let payload = payload { ring(payload) }
        case "call:ended": if let payload = payload { ended(payload) }
        case "call:taken": if let id = payload?["callId"] as? String { stopRinging(id) }
        case "chat:message": if let payload = payload { message(payload) }
        default: break
        }
    }

    // MARK: - Notifications

    private func ring(_ call: [String: Any]) {
        guard let id = call["callId"] as? String, let conversation = call["conversationId"] as? String else { return }
        let strings = BackgroundCheck.strings
        var name = strings["someone"] ?? "Digistban"
        if let caller = (call["from"] as? [String: Any])?["name"] as? String, !caller.isEmpty { name = caller }
        ringing[id] = (name, conversation)
        let video = (call["kind"] as? String) == "video"
        NativeCalls.shared.reportIncoming(id: id, conversation: conversation, name: name, video: video) { [weak self] in
            // iOS refused the call screen (Focus, another call…): ring with a notification instead.
            self?.notifyRinging(id: id, conversation: conversation, name: name, video: video)
        }
    }

    private func notifyRinging(id: String, conversation: String, name: String, video: Bool) {
        let strings = BackgroundCheck.strings
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = (video ? strings["incomingVideo"] : strings["incomingAudio"]) ?? "Appel entrant"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("ring.wav"))
        content.categoryIdentifier = "call"
        content.threadIdentifier = conversation
        content.userInfo = ["path": "/messages/\(conversation)?call=\(id)", "callId": id]
        let request = UNNotificationRequest(identifier: "call-\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
        // A notification sound lasts 30 s at most and the call rings for 45 s: ring once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard self?.ringing[id] != nil else { return }
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    }

    private func stopRinging(_ id: String, reason: CXCallEndedReason = .answeredElsewhere) {
        ringing[id] = nil
        NativeCalls.shared.end(id, reason: reason)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["call-\(id)"])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["call-\(id)"])
    }

    private func ended(_ payload: [String: Any]) {
        guard let id = payload["callId"] as? String, let call = ringing[id] else { return }
        let reason = payload["reason"] as? String
        stopRinging(id, reason: reason == "missed" ? .unanswered : reason == "declined" ? .declinedElsewhere : .remoteEnded)
        guard reason == "missed" || reason == "cancelled" else { return }
        Notifications.show(
            id: "missed-\(id)",
            title: call.name,
            body: BackgroundCheck.strings["call"] ?? "Appel manqué",
            path: "/messages/\(call.conversation)",
            thread: call.conversation
        )
    }

    private func message(_ message: [String: Any]) {
        guard let conversation = message["conversationId"] as? String,
              let sender = message["senderId"] as? String, sender != BackgroundCheck.userId else { return }
        let kind = message["kind"] as? String
        // Calls are notified by ring() and ended().
        guard kind != "call" else { return }
        let strings = BackgroundCheck.strings
        var title = strings["newMessage"] ?? "Digistban"
        if let name = message["senderName"] as? String, !name.isEmpty { title = name }
        let body: String
        switch kind {
        case "voice": body = strings["voice"] ?? "Message vocal"
        case "transfer": body = strings["transfer"] ?? "Fichiers"
        default: body = (message["body"] as? String) ?? ""
        }
        Notifications.show(id: "conversation-\(conversation)", title: title, body: body, path: "/messages/\(conversation)", thread: conversation)
        if let at = message["createdAt"] as? String { BackgroundCheck.markNotified(conversation, at: at) }
    }
}
