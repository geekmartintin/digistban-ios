import UIKit
import WebKit

/// Files downloaded in the app go through the system's own download service
/// (a background URLSession): they go on when the app is left, with their
/// progress in the Dynamic Island and on the Lock Screen, and open in Quick Look
/// at the end. The page's download links (`<a download>`) are caught before
/// any request is sent, so a link with a download limit counts only once.
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
    private(set) var active: [Int: Progress] = [:]
    /// The last file downloaded (Lock Screen activity, notification).
    private(set) var lastFile: URL?
    private var finished: [Int: URL] = [:]
    private var failures: [Int: String] = [:]
    private var lastChange = Date.distantPast

    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: BackgroundDownloads.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    private static func activityId(_ task: Int) -> String { "download-\(task)" }

    /// At launch: downloads started before (maybe while the app was stopped) report again.
    func reconnect() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var running = Set<String>()
                for task in tasks where task.state == .running {
                    self.active[task.taskIdentifier] = Progress(name: task.taskDescription ?? "", received: task.countOfBytesReceived, expected: task.countOfBytesExpectedToReceive)
                    running.insert(BackgroundDownloads.activityId(task.taskIdentifier))
                }
                LiveActivities.endDownloads(except: running)
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
            let task = self.session.downloadTask(with: request)
            let title = BackgroundCheck.strings["downloadTitle"] ?? "Téléchargement"
            task.taskDescription = title
            self.active[task.taskIdentifier] = Progress(name: title, received: 0, expected: -1)
            LiveActivities.startDownload(id: BackgroundDownloads.activityId(task.taskIdentifier), title: title)
            Haptics.play("light")
            Diagnostics.note("download-start")
            task.resume()
            self.onChange?()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        var progress = active[id] ?? Progress(name: downloadTask.taskDescription ?? "", received: 0, expected: -1)
        progress.received = totalBytesWritten
        progress.expected = totalBytesExpectedToWrite
        if progress.expected <= 0, let hint = (downloadTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Digistban-Size"), let size = Int64(hint), size > 0 {
            // "Download everything": a ZIP built on the fly has no length, the server says about how big.
            progress.expected = size
        }
        if let name = downloadTask.response?.suggestedFilename, !name.isEmpty { progress.name = name }
        active[id] = progress
        LiveActivities.updateDownload(id: BackgroundDownloads.activityId(id), name: progress.name, received: progress.received, expected: progress.expected)
        let now = Date()
        if now.timeIntervalSince(lastChange) > 0.2 {
            lastChange = now
            onChange?()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` disappears when this returns: keep it now.
        let id = downloadTask.taskIdentifier
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // An error page (expired link, limit reached…): its message, in the account's language.
            let json = (try? Data(contentsOf: location)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            failures[id] = (json?["error"] as? [String: Any])?["message"] as? String ?? NSLocalizedString("download.failed", comment: "")
            return
        }
        let name = AppGroup.safeName(downloadTask.response?.suggestedFilename ?? downloadTask.taskDescription ?? "Digistban")
        let folder = Downloads.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: target)
            finished[id] = target
        } catch {
            failures[id] = error.localizedDescription
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let progress = active.removeValue(forKey: id)
        let strings = BackgroundCheck.strings
        if let file = finished.removeValue(forKey: id), error == nil {
            lastFile = file
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? progress?.received ?? 0
            LiveActivities.endDownload(id: BackgroundDownloads.activityId(id), name: file.lastPathComponent, size: size, error: nil)
            Diagnostics.note("download-done")
            if UIApplication.shared.applicationState == .active {
                WebViewController.shared.presentDownloaded(file)
            } else {
                Notifications.show(id: "download-\(id)", title: strings["downloadDone"] ?? "Téléchargement terminé", body: file.lastPathComponent, path: nil, thread: nil, extra: ["file": file.path])
            }
        } else {
            let message = failures.removeValue(forKey: id) ?? error?.localizedDescription ?? NSLocalizedString("download.failed", comment: "")
            LiveActivities.endDownload(id: BackgroundDownloads.activityId(id), name: progress?.name ?? "", size: progress?.received ?? 0, error: message)
            Diagnostics.note("download-failed")
            if UIApplication.shared.applicationState == .active {
                WebViewController.shared.showDownloadError(message)
            } else {
                Notifications.show(id: "download-\(id)", title: strings["downloadFailed"] ?? NSLocalizedString("download.failed", comment: ""), body: message, path: nil, thread: nil)
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
