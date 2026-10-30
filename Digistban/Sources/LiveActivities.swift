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
        guard #available(iOS 16.2, *) else { return }
        guard activities[job.id] == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = UploadActivityAttributes(jobId: job.id, title: job.title, fileCount: job.files.count)
        do {
            let activity = try Activity<UploadActivityAttributes>.request(
                attributes: attributes,
                content: ActivityContent(state: state(job, sent: Uploader.shared.uploadedBytes(job)), staleDate: nil),
                pushType: nil
            )
            activities[job.id] = activity
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

    /// After a restart: picks up the activities of jobs still running, ends the others.
    static func restore(jobs: [Uploader.Job]) {
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<UploadActivityAttributes>.activities {
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
            link: link
        )
    }
}
