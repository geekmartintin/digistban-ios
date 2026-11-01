import ActivityKit
import Foundation

/// Progress of transfers on the Lock Screen and in the Dynamic Island. The app
/// starts an activity when sending begins (it must be in front for that), then
/// updates it while it runs in the background, and ends it with the result.
enum LiveActivities {
    /// Activity per job id (typed as Any: ActivityKit exists from iOS 16.1).
    private static var activities: [String: Any] = [:]
    private static var lastUpdate: [String: Date] = [:]

    static func start(_ job: Uploader.Job) {
        guard #available(iOS 16.2, *) else {
            Diagnostics.note("activity-unsupported")
            return
        }
        guard activities[job.id] == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Diagnostics.note("activity-disabled")
            return
        }
        let attributes = UploadActivityAttributes(jobId: job.id, title: job.title, fileCount: job.files.count, kind: "upload")
        do {
            let activity = try Activity<UploadActivityAttributes>.request(
                attributes: attributes,
                content: ActivityContent(state: state(job, sent: Uploader.shared.uploadedBytes(job)), staleDate: nil),
                pushType: nil
            )
            activities[job.id] = activity
            Diagnostics.note("activity-started-\(activity.activityState == .active ? "active" : "inactive")")
        } catch {
            Diagnostics.note("activity-\(Diagnostics.code(error))")
        }
    }

    static func update(_ job: Uploader.Job, sent: Int64, force: Bool = false) {
        guard #available(iOS 16.2, *), let activity = activities[job.id] as? Activity<UploadActivityAttributes> else { return }
        let now = Date()
        // iOS limits how often an activity may change: about once a second is plenty.
        if !force, let last = lastUpdate[job.id], now.timeIntervalSince(last) < 1.5 { return }
        lastUpdate[job.id] = now
        let content = ActivityContent(state: state(job, sent: sent), staleDate: nil)
        Task { await activity.update(content) }
    }

    static func end(_ job: Uploader.Job) {
        guard #available(iOS 16.2, *), let activity = activities.removeValue(forKey: job.id) as? Activity<UploadActivityAttributes> else { return }
        lastUpdate[job.id] = nil
        let content = ActivityContent(state: state(job, sent: Uploader.shared.uploadedBytes(job)), staleDate: nil)
        // The result stays a quarter of an hour on the Lock Screen; a cancelled send goes at once.
        let policy: ActivityUIDismissalPolicy = job.status == "cancelled" ? .immediate : .after(Date().addingTimeInterval(15 * 60))
        Task { await activity.end(content, dismissalPolicy: policy) }
    }

    // MARK: - Downloads

    static func startDownload(id: String, title: String) {
        guard #available(iOS 16.2, *), activities[id] == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Diagnostics.note("activity-disabled")
            return
        }
        let attributes = UploadActivityAttributes(jobId: id, title: title, fileCount: 1, kind: "download")
        do {
            let activity = try Activity<UploadActivityAttributes>.request(
                attributes: attributes,
                content: ActivityContent(state: downloadState(name: nil, received: 0, expected: -1, error: nil, done: false), staleDate: nil),
                pushType: nil
            )
            activities[id] = activity
            Diagnostics.note("activity-download-\(activity.activityState == .active ? "active" : "inactive")")
        } catch {
            Diagnostics.note("activity-\(Diagnostics.code(error))")
        }
    }

    static func updateDownload(id: String, name: String, received: Int64, expected: Int64) {
        guard #available(iOS 16.2, *), let activity = activities[id] as? Activity<UploadActivityAttributes> else { return }
        let now = Date()
        if let last = lastUpdate[id], now.timeIntervalSince(last) < 1 { return }
        lastUpdate[id] = now
        let content = ActivityContent(state: downloadState(name: name, received: received, expected: expected, error: nil, done: false), staleDate: nil)
        Task { await activity.update(content) }
    }

    static func endDownload(id: String, name: String, size: Int64, error: String?) {
        guard #available(iOS 16.2, *), let activity = activities.removeValue(forKey: id) as? Activity<UploadActivityAttributes> else { return }
        lastUpdate[id] = nil
        let content = ActivityContent(state: downloadState(name: name, received: size, expected: size, error: error, done: true), staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(15 * 60))) }
    }

    /// After a restart: download activities whose download is over.
    static func endDownloads(except running: Set<String>) {
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<UploadActivityAttributes>.activities where activity.attributes.kind == "download" && !running.contains(activity.attributes.jobId) {
            activities[activity.attributes.jobId] = nil
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    @available(iOS 16.2, *)
    private static func downloadState(name: String?, received: Int64, expected: Int64, error: String?, done: Bool) -> UploadActivityAttributes.ContentState {
        let strings = BackgroundCheck.strings
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        let status = error != nil ? "failed" : done ? "completed" : "uploading"
        var detail = bytes.string(fromByteCount: received)
        if expected > 0 && !done {
            detail = (strings["sentOf"] ?? "{sent} / {total}")
                .replacingOccurrences(of: "{sent}", with: bytes.string(fromByteCount: received))
                .replacingOccurrences(of: "{total}", with: bytes.string(fromByteCount: expected))
        }
        if let error = error { detail = error }
        let label = error != nil ? (strings["downloadFailed"] ?? "Échec") : done ? (strings["downloadDone"] ?? "Téléchargé") : (strings["downloading"] ?? "Téléchargement")
        return UploadActivityAttributes.ContentState(
            // An estimated size may be a little off: never "100 %" before the end.
            fraction: done ? 1 : expected > 0 ? min(0.99, Double(received) / Double(expected)) : 0,
            status: status,
            label: label,
            detail: detail,
            link: "digistban://download",
            title: name
        )
    }

    /// After a restart: picks up the activities of jobs still running, ends the others.
    static func restore(jobs: [Uploader.Job]) {
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<UploadActivityAttributes>.activities where activity.attributes.kind != "download" {
            let id = activity.attributes.jobId
            if let job = jobs.first(where: { $0.id == id }), ["preparing", "uploading", "finalizing", "paused"].contains(job.status) {
                activities[id] = activity
            } else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }

    @available(iOS 16.2, *)
    private static func state(_ job: Uploader.Job, sent: Int64) -> UploadActivityAttributes.ContentState {
        let strings = BackgroundCheck.strings
        let total = job.files.reduce(Int64(0)) { $0 + $1.size }
        let fraction = total > 0 ? min(1, Double(sent) / Double(total)) : 0
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        var detail = (strings["sentOf"] ?? "{sent} / {total}")
            .replacingOccurrences(of: "{sent}", with: bytes.string(fromByteCount: sent))
            .replacingOccurrences(of: "{total}", with: bytes.string(fromByteCount: total))
        if job.status == "completed" {
            detail = bytes.string(fromByteCount: total)
        } else if job.status == "failed", let error = job.error {
            detail = error
        }
        let link = job.transferId.map { "digistban://transfers/\($0)" } ?? "digistban://transfers"
        return UploadActivityAttributes.ContentState(
            fraction: job.status == "completed" ? 1 : fraction,
            status: job.status,
            label: strings["status.\(job.status)"] ?? job.status,
            detail: detail,
            link: link,
            title: nil
        )
    }
}
