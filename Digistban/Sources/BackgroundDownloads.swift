import UIKit
import WebKit

/// Files downloaded in the app go through the system's own download service
/// (a background URLSession): they go on when the app is left, with their
/// progress in the Dynamic Island and on the Lock Screen, and open in Quick Look
/// at the end. The page's download links (`<a download>`) are caught before
/// any request is sent, so a link with a download limit counts only once.
/// The Live Activity's buttons pause, resume or cancel them (TransferControl).
final class BackgroundDownloads: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloads()
    static let identifier = "com.digistban.app.downloads"

    struct Progress {
        var name: String
        var received: Int64
        var expected: Int64
    }

    /// Given by iOS when it woke the app for finished downloads.
    var systemCompletion: (() -> Void)?
    /// Something changed (the in-app progress pill listens).
    var onChange: (() -> Void)?
    /// Downloads under way or paused, by job id ("download-…", also their Live Activity's).
    private(set) var active: [String: Progress] = [:]
    /// The last file downloaded (Lock Screen activity, notification, "Share").
    private(set) var lastFile: URL?
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var requests: [String: URLRequest] = [:]
    /// Paused downloads, and what URLSession needs to pick up where it stopped
    /// (none when the server cannot resume: it starts again from the beginning).
    private var paused = Set<String>()
    private var resumeData: [String: Data] = [:]
    private var cancelled = Set<String>()
    private var finished: [String: URL] = [:]
    private var failures: [String: String] = [:]
    private var lastChange = Date.distantPast

    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: BackgroundDownloads.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    /// "job<tab>title": the job id travels with the task, across pauses and app restarts.
    private static func job(of task: URLSessionTask) -> String {
        let description = task.taskDescription ?? ""
        guard let tab = description.firstIndex(of: "\t") else { return "download-\(task.taskIdentifier)" }
        return String(description[..<tab])
    }

    private static func title(of task: URLSessionTask) -> String {
        let description = task.taskDescription ?? ""
        guard let tab = description.firstIndex(of: "\t") else { return description }
        return String(description[description.index(after: tab)...])
    }

    /// At launch: downloads started before (maybe while the app was stopped) report again.
    func reconnect() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var running = Set<String>()
                for case let task as URLSessionDownloadTask in tasks where task.state == .running {
                    let job = BackgroundDownloads.job(of: task)
                    self.tasks[job] = task
                    self.active[job] = Progress(name: BackgroundDownloads.title(of: task), received: task.countOfBytesReceived, expected: task.countOfBytesExpectedToReceive)
                    running.insert(job)
                }
                LiveActivities.endDownloads(except: running.union(self.paused))
                self.onChange?()
            }
        }
    }

    func start(url: URL) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let host = url.host?.lowercased() ?? ""
            // The session, and for a protected link its unlock cookie (scoped to the link's path).
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return (host == domain || host.hasSuffix("." + domain)) && url.path.hasPrefix(cookie.path)
            }
            var request = URLRequest(url: url)
            for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            request.setValue(BackgroundCheck.language ?? "fr", forHTTPHeaderField: "X-Digistban-Lang")
            let title = BackgroundCheck.strings["downloadTitle"] ?? "Téléchargement"
            let job = "download-\(UUID().uuidString.prefix(8).lowercased())"
            self.requests[job] = request
            self.active[job] = Progress(name: title, received: 0, expected: -1)
            LiveActivities.startDownload(id: job, title: title)
            self.launch(job: job, task: self.session.downloadTask(with: request), title: title)
            Haptics.play("light")
            Diagnostics.note("download-start")
        }
    }

    private func launch(job: String, task: URLSessionDownloadTask, title: String) {
        task.taskDescription = "\(job)\t\(title)"
        tasks[job] = task
        task.resume()
        onChange?()
    }

    /// Buttons of the Live Activity (and of the app): "pause", "resume", "cancel".
    func control(job: String, action: String) {
        guard var progress = active[job] else { return }
        switch action {
        case "pause":
            guard !paused.contains(job), let task = tasks[job] else { return }
            paused.insert(job)
            LiveActivities.pauseDownload(id: job, name: progress.name, received: progress.received, expected: progress.expected)
            task.cancel { [weak self] data in
                DispatchQueue.main.async { self?.resumeData[job] = data }
            }
            Diagnostics.note("download-paused")
        case "resume":
            guard paused.remove(job) != nil else { return }
            let task: URLSessionDownloadTask
            if let data = resumeData.removeValue(forKey: job) {
                task = session.downloadTask(withResumeData: data)
            } else if let request = requests[job] {
                task = session.downloadTask(with: request)
                progress.received = 0
                active[job] = progress
            } else {
                return
            }
            LiveActivities.updateDownload(id: job, name: progress.name, received: progress.received, expected: progress.expected, force: true)
            launch(job: job, task: task, title: progress.name)
            Diagnostics.note("download-resumed")
        case "cancel":
            if paused.remove(job) != nil {
                resumeData[job] = nil
                requests[job] = nil
                active[job] = nil
                LiveActivities.endDownload(id: job, name: progress.name, size: progress.received, error: nil, cancelled: true)
                onChange?()
            } else {
                cancelled.insert(job)
                tasks[job]?.cancel()
            }
            Diagnostics.note("download-cancelled")
        default:
            break
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let job = BackgroundDownloads.job(of: downloadTask)
        guard !paused.contains(job) else { return }
        var progress = active[job] ?? Progress(name: BackgroundDownloads.title(of: downloadTask), received: 0, expected: -1)
        progress.received = totalBytesWritten
        progress.expected = totalBytesExpectedToWrite
        if progress.expected <= 0, let hint = (downloadTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Digistban-Size"), let size = Int64(hint), size > 0 {
            // "Download everything": a ZIP built on the fly has no length, the server says about how big.
            progress.expected = size
        }
        if let name = downloadTask.response?.suggestedFilename, !name.isEmpty { progress.name = name }
        active[job] = progress
        LiveActivities.updateDownload(id: job, name: progress.name, received: progress.received, expected: progress.expected)
        let now = Date()
        if now.timeIntervalSince(lastChange) > 0.2 {
            lastChange = now
            onChange?()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` disappears when this returns: keep it now.
        let job = BackgroundDownloads.job(of: downloadTask)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // An error page (expired link, limit reached…): its message, in the account's language.
            let json = (try? Data(contentsOf: location)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            failures[job] = (json?["error"] as? [String: Any])?["message"] as? String ?? NSLocalizedString("download.failed", comment: "")
            return
        }
        let name = AppGroup.safeName(downloadTask.response?.suggestedFilename ?? BackgroundDownloads.title(of: downloadTask))
        let folder = Downloads.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: target)
            finished[job] = target
        } catch {
            failures[job] = error.localizedDescription
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let job = BackgroundDownloads.job(of: task)
        tasks[job] = nil
        // Paused: the task was stopped on purpose, the activity stays (showing "paused").
        if paused.contains(job) { return }
        let progress = active.removeValue(forKey: job)
        requests[job] = nil
        let strings = BackgroundCheck.strings
        if cancelled.remove(job) != nil {
            LiveActivities.endDownload(id: job, name: progress?.name ?? "", size: progress?.received ?? 0, error: nil, cancelled: true)
        } else if let file = finished.removeValue(forKey: job), error == nil {
            lastFile = file
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? progress?.received ?? 0
            LiveActivities.endDownload(id: job, name: file.lastPathComponent, size: size, error: nil)
            Diagnostics.note("download-done")
            if UIApplication.shared.applicationState == .active {
                WebViewController.shared.presentDownloaded(file)
            } else {
                Notifications.show(id: job, title: strings["downloadDone"] ?? "Téléchargement terminé", body: file.lastPathComponent, path: nil, thread: nil, extra: ["file": file.path])
            }
        } else {
            let message = failures.removeValue(forKey: job) ?? error?.localizedDescription ?? NSLocalizedString("download.failed", comment: "")
            LiveActivities.endDownload(id: job, name: progress?.name ?? "", size: progress?.received ?? 0, error: message)
            Diagnostics.note("download-failed")
            if UIApplication.shared.applicationState == .active {
                WebViewController.shared.showDownloadError(message)
            } else {
                Notifications.show(id: job, title: strings["downloadFailed"] ?? NSLocalizedString("download.failed", comment: ""), body: message, path: nil, thread: nil)
            }
        }
        onChange?()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = systemCompletion
        systemCompletion = nil
        completion?()
    }
}

/// Small progress capsule at the top of the app while files download (the
/// Dynamic Island only shows it once you have left the app).
final class DownloadPill: UIVisualEffectView {
    private let icon = UIImageView(image: UIImage(systemName: "arrow.down.circle.fill"))
    private let label = UILabel()
    private let bar = UIProgressView(progressViewStyle: .bar)

    init() {
        super.init(effect: UIBlurEffect(style: .systemThickMaterialDark))
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isUserInteractionEnabled = false
        alpha = 0
        icon.tintColor = .white
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        bar.progressTintColor = .white
        bar.trackTintColor = UIColor(white: 1, alpha: 0.2)
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.spacing = 8
        row.alignment = .center
        let stack = UIStackView(arrangedSubviews: [row, bar])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -9),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            bar.heightAnchor.constraint(equalToConstant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the total progress of the downloads under way, or hides when there are none.
    func refresh(_ downloads: [BackgroundDownloads.Progress]) {
        guard !downloads.isEmpty else {
            UIView.animate(withDuration: 0.25) { self.alpha = 0 }
            return
        }
        let received = downloads.reduce(Int64(0)) { $0 + $1.received }
        let expected = downloads.reduce(Int64(0)) { $0 + max(0, $1.expected) }
        let bytes = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        let title = downloads.count == 1 ? downloads[0].name : (BackgroundCheck.strings["downloadTitle"] ?? "Téléchargement")
        if expected > 0 {
            let fraction = min(1, Float(received) / Float(expected))
            label.text = "\(Int(fraction * 100)) % · \(title)"
            bar.setProgress(fraction, animated: true)
            bar.isHidden = false
        } else {
            label.text = "\(bytes) · \(title)"
            bar.isHidden = true
        }
        if alpha < 1 {
            transform = CGAffineTransform(translationX: 0, y: -8)
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
                self.alpha = 1
                self.transform = .identity
            }
        }
    }
}
