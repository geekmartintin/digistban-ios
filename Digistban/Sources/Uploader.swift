import Foundation
import UIKit

/// Sends transfers from the app itself, the way the page does: 8 MiB chunks,
/// each confirmed by the server (which says where it stopped), so a network
/// cut or a restart resumes exactly there. While something is being sent, the
/// app keeps running in the background (KeepAlive): leaving the app does not
/// stop it. The page only shows the progress (`upload` events), with the same
/// job shape as its own engine (frontend/src/context/UploadContext.tsx).
final class Uploader: NSObject, URLSessionTaskDelegate {
    static let shared = Uploader()
    private static let api = "https://digistban.com/help/api"

    struct File: Codable {
        var key: String
        var name: String
        var size: Int64
        var type: String
        var serverId: String?
        var uploaded: Int64
        var status: String
        var error: String?
    }

    struct Job: Codable {
        var id: String
        var title: String
        /// Body of POST /transfers as the page wrote it (title, message, expiry, password, limit).
        var options: Data
        var transferId: String?
        var chunkSize: Int
        var files: [File]
        var status: String
        var error: String?
        var notice: String?
        var startedAt: Double
        /// The finalised transfer, as the server returned it.
        var result: Data?
    }

    private static let active: Set<String> = ["preparing", "uploading", "finalizing"]
    private static let retryDelays: [Double] = [1, 2, 4, 8, 15, 30, 30, 30, 60, 60]

    private var jobs: [Job] = []
    private var runningId: String?
    private var task: URLSessionTask?
    /// Bytes of the chunk in flight, as reported by the system.
    private var inFlight: Int64 = 0
    private var attempt = 0
    /// Files whose position was asked to the server since launch.
    private var synced = Set<String>()
    private var speed: Double?
    private var lastBytes: Int64 = 0
    private var lastTick = Date()
    private var lastEmit = Date.distantPast
    private var lastSave = Date.distantPast
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // Without network, requests wait for it instead of failing.
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    private static var store: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("uploads.json")
    }

    /// Something is being sent (the app then stays running in the background).
    var isBusy: Bool {
        jobs.contains { Uploader.active.contains($0.status) }
    }

    // MARK: - Lifecycle

    /// At launch: jobs from before; those that were not paused go on.
    func restore() {
        if let data = try? Data(contentsOf: Uploader.store), let saved = try? JSONDecoder().decode([Job].self, from: data) {
            jobs = saved
        }
        Staging.cleanUp(keeping: Set(jobs.flatMap { job in job.files.map { $0.key } }))
        LiveActivities.restore(jobs: jobs)
        pump()
    }

    private func save(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSave) > 2 else { return }
        lastSave = Date()
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? FileManager.default.createDirectory(at: Uploader.store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Uploader.store, options: .atomic)
    }

    // MARK: - From the page

    /// `upload` message: { id, title, options, files: [{ id, name, size, type }] }.
    func start(_ message: [String: Any]) {
        guard let id = message["id"] as? String, !jobs.contains(where: { $0.id == id }),
              let list = message["files"] as? [[String: Any]], !list.isEmpty else { return }
        let options = (message["options"] as? [String: Any]) ?? [:]
        let files: [File] = list.compactMap { entry in
            guard let key = entry["id"] as? String, let item = Staging.item(id: key) else { return nil }
            return File(key: key, name: (entry["name"] as? String) ?? item.name, size: item.size, type: (entry["type"] as? String) ?? item.type, serverId: nil, uploaded: 0, status: "queued", error: nil)
        }
        var job = Job(
            id: id,
            title: (message["title"] as? String) ?? files.first?.name ?? "Digistban",
            options: (try? JSONSerialization.data(withJSONObject: options)) ?? Data("{}".utf8),
            transferId: nil,
            chunkSize: 8 * 1024 * 1024,
            files: files,
            status: "preparing",
            error: nil,
            notice: nil,
            startedAt: Date().timeIntervalSince1970 * 1000,
            result: nil
        )
        if files.count != list.count {
            job.status = "failed"
            job.error = BackgroundCheck.strings["missingSource"] ?? "Fichier introuvable."
        }
        jobs.insert(job, at: 0)
        save(force: true)
        emit(job, force: true)
        if job.status == "preparing" { LiveActivities.start(job) }
        pump()
    }

    /// Pause, resume, cancel or forget a job (`uploadControl` message).
    func control(_ id: String, action: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch action {
        case "pause":
            guard Uploader.active.contains(jobs[index].status) else { return }
            if runningId == id { stopRunning() }
            jobs[index].status = "paused"
        case "resume":
            guard jobs[index].status == "paused" || jobs[index].status == "failed" else { return }
            jobs[index].status = jobs[index].transferId == nil ? "preparing" : "uploading"
            jobs[index].error = nil
            for file in jobs[index].files.indices where jobs[index].files[file].status != "completed" {
                jobs[index].files[file].status = "queued"
                jobs[index].files[file].error = nil
            }
            synced.removeAll()
            LiveActivities.start(jobs[index])
        case "cancel":
            if runningId == id { stopRunning() }
            jobs[index].status = "cancelled"
            if let transferId = jobs[index].transferId { request("DELETE", "/transfers/\(transferId)") { _, _ in } }
            jobs[index].files.forEach { Staging.remove($0.key) }
            LiveActivities.end(jobs[index])
        case "dismiss":
            if runningId == id { stopRunning() }
            let job = jobs.remove(at: index)
            job.files.forEach { Staging.remove($0.key) }
            LiveActivities.end(job)
            save(force: true)
            pump()
            return
        default:
            return
        }
        save(force: true)
        emit(jobs[index], force: true)
        LiveActivities.update(jobs[index], sent: uploadedBytes(jobs[index]), force: true)
        pump()
    }

    /// The page (re)started: it gets every job.
    func broadcast() {
        jobs.forEach { emit($0, force: true) }
    }

    // MARK: - Engine

    private func stopRunning() {
        let current = task
        task = nil
        runningId = nil
        inFlight = 0
        current?.cancel()
    }

    /// Runs the next active job; one at a time.
    private func pump() {
        guard runningId == nil else { return }
        guard let job = jobs.first(where: { Uploader.active.contains($0.status) }) else {
            endBackgroundTask()
            return
        }
        runningId = job.id
        attempt = 0
        speed = nil
        lastBytes = uploadedBytes(job)
        lastTick = Date()
        beginBackgroundTask()
        step()
    }

    private func current() -> Int? {
        guard let id = runningId else { return nil }
        return jobs.firstIndex { $0.id == id }
    }

    private func step() {
        guard let i = current() else { return }
        guard Uploader.active.contains(jobs[i].status) else {
            runningId = nil
            pump()
            return
        }
        if jobs[i].transferId == nil {
            create()
        } else if let next = jobs[i].files.firstIndex(where: { $0.status != "completed" && $0.status != "failed" }) {
            send(next)
        } else if jobs[i].files.contains(where: { $0.status == "failed" }) {
            finish(status: "failed", error: BackgroundCheck.strings["someFailed"] ?? "Certains fichiers n’ont pas pu être envoyés.")
        } else {
            finalizeTransfer()
        }
    }

    private func create() {
        guard let i = current() else { return }
        var body = (try? JSONSerialization.jsonObject(with: jobs[i].options) as? [String: Any]) ?? [:]
        body["files"] = jobs[i].files.map { file -> [String: Any] in
            ["name": file.name, "size": file.size, "type": file.type.isEmpty ? (NSNull() as Any) : (file.type as Any)]
        }
        request("POST", "/transfers", json: body) { [weak self] status, data in
            guard let self = self, let i = self.current() else { return }
            let json = Uploader.object(data)
            guard (200..<300).contains(status), let id = json?["id"] as? String else {
                self.failure(status: status, json: json) { self.create() }
                return
            }
            self.jobs[i].transferId = id
            if let size = json?["chunkSize"] as? Int, size > 0 { self.jobs[i].chunkSize = size }
            let serverFiles = (json?["files"] as? [[String: Any]]) ?? []
            for (index, file) in serverFiles.enumerated() where index < self.jobs[i].files.count {
                self.jobs[i].files[index].serverId = file["id"] as? String
            }
            self.jobs[i].status = "uploading"
            self.attempt = 0
            self.save(force: true)
            self.emit(self.jobs[i], force: true)
            LiveActivities.update(self.jobs[i], sent: 0, force: true)
            self.step()
        }
    }

    private func send(_ f: Int) {
        guard let i = current() else { return }
        let file = jobs[i].files[f]
        guard let transferId = jobs[i].transferId, let serverId = file.serverId, let item = Staging.item(id: file.key) else {
            failFile(f, BackgroundCheck.strings["missingSource"] ?? "Fichier introuvable.")
            return
        }
        if file.status != "uploading" {
            jobs[i].files[f].status = "uploading"
            emit(jobs[i], force: true)
        }
        let base = "/transfers/\(transferId)/files/\(serverId)"

        // After a restart or an error: ask the server where it stopped.
        if !synced.contains(file.key) && file.uploaded > 0 {
            request("GET", base + "/offset") { [weak self] status, data in
                guard let self = self, let i = self.current() else { return }
                let json = Uploader.object(data)
                guard (200..<300).contains(status) else {
                    self.failure(status: status, json: json) { self.send(f) }
                    return
                }
                self.synced.insert(file.key)
                if json?["complete"] as? Bool == true {
                    self.jobs[i].files[f].uploaded = file.size
                    self.jobs[i].files[f].status = "completed"
                    self.step()
                } else {
                    self.jobs[i].files[f].uploaded = Uploader.int64(json?["uploadedBytes"]) ?? 0
                    self.send(f)
                }
            }
            return
        }
        synced.insert(file.key)

        let offset = jobs[i].files[f].uploaded
        guard offset < file.size else {
            complete(f)
            return
        }
        let length = Int(min(Int64(jobs[i].chunkSize), file.size - offset))
        guard let chunk = Uploader.read(item.url, offset: offset, length: length), !chunk.isEmpty else {
            failFile(f, BackgroundCheck.strings["missingSource"] ?? "Fichier introuvable.")
            return
        }
        guard let url = URL(string: Uploader.api + base + "/content?offset=\(offset)") else { return }
        var chunkRequest = URLRequest(url: url)
        chunkRequest.httpMethod = "PUT"
        Uploader.authorize(&chunkRequest)
        chunkRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        inFlight = 0
        let upload = session.uploadTask(with: chunkRequest, from: chunk) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
            self.task = nil
            self.inFlight = 0
            guard let i = self.current(), f < self.jobs[i].files.count, self.jobs[i].files[f].key == file.key else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = Uploader.object(data)
            let problem = json?["error"] as? [String: Any]
            if (200..<300).contains(status), let uploaded = Uploader.int64(json?["uploadedBytes"]) {
                self.attempt = 0
                self.jobs[i].notice = nil
                self.jobs[i].files[f].uploaded = uploaded
                self.save()
                self.emit(self.jobs[i])
                LiveActivities.update(self.jobs[i], sent: self.uploadedBytes(self.jobs[i]))
                if uploaded >= file.size { self.complete(f) } else { self.send(f) }
            } else if let uploaded = Uploader.int64(problem?["uploadedBytes"]) {
                // The server says where it actually is: go on from there.
                self.jobs[i].files[f].uploaded = uploaded
                self.send(f)
            } else if status == 409, problem?["code"] as? String == "upload_busy" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.send(f) }
            } else if status == 0 || status == 429 || status >= 500 {
                self.synced.remove(file.key)
                self.failure(status: status, json: json) { self.send(f) }
            } else {
                self.failFile(f, (problem?["message"] as? String) ?? BackgroundCheck.strings["refused"] ?? "Le serveur a refusé ce fichier.")
            }
        }
        task = upload
        upload.resume()
    }

    private func complete(_ f: Int) {
        guard let i = current(), let transferId = jobs[i].transferId, let serverId = jobs[i].files[f].serverId else { return }
        jobs[i].files[f].status = "processing"
        emit(jobs[i], force: true)
        request("POST", "/transfers/\(transferId)/files/\(serverId)/complete") { [weak self] status, data in
            guard let self = self, let i = self.current() else { return }
            guard (200..<300).contains(status) else {
                self.failure(status: status, json: Uploader.object(data)) { self.complete(f) }
                return
            }
            self.jobs[i].files[f].status = "completed"
            self.jobs[i].files[f].uploaded = self.jobs[i].files[f].size
            self.save(force: true)
            self.emit(self.jobs[i], force: true)
            self.step()
        }
    }

    private func finalizeTransfer() {
        guard let i = current(), let transferId = jobs[i].transferId else { return }
        jobs[i].status = "finalizing"
        emit(jobs[i], force: true)
        LiveActivities.update(jobs[i], sent: uploadedBytes(jobs[i]), force: true)
        request("POST", "/transfers/\(transferId)/finalize") { [weak self] status, data in
            guard let self = self, let i = self.current() else { return }
            guard (200..<300).contains(status), let data = data else {
                self.failure(status: status, json: Uploader.object(data)) { self.finalizeTransfer() }
                return
            }
            self.jobs[i].result = data
            self.finish(status: "completed", error: nil)
        }
    }

    private func failFile(_ f: Int, _ message: String) {
        guard let i = current() else { return }
        jobs[i].files[f].status = "failed"
        jobs[i].files[f].error = message
        save(force: true)
        emit(jobs[i], force: true)
        step()
    }

    /// A request did not succeed: try again later (network, busy server) or give up (refused).
    private func failure(status: Int, json: [String: Any]?, retry: @escaping () -> Void) {
        guard let i = current() else { return }
        guard status == 0 || status == 429 || status >= 500 else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            finish(status: "failed", error: message ?? BackgroundCheck.strings["failed"] ?? "L’envoi a échoué.")
            return
        }
        guard attempt < Uploader.retryDelays.count else {
            finish(status: "failed", error: BackgroundCheck.strings["failedRepeatedly"] ?? "La connexion au serveur a échoué à plusieurs reprises.")
            return
        }
        jobs[i].notice = BackgroundCheck.strings["unstable"]
        emit(jobs[i], force: true)
        let delay = Uploader.retryDelays[attempt]
        attempt += 1
        let id = runningId
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.runningId == id else { return }
            retry()
        }
    }

    private func finish(status: String, error: String?) {
        guard let i = current() else { return }
        jobs[i].status = status
        jobs[i].error = error
        jobs[i].notice = nil
        let job = jobs[i]
        if status == "completed" { job.files.forEach { Staging.remove($0.key) } }
        save(force: true)
        emit(job, force: true)
        LiveActivities.end(job)
        notifyIfAway(job)
        runningId = nil
        pump()
        // Nothing left to send and nobody asked to stay reachable: let iOS suspend the app.
        if !isBusy && !KeepAlive.enabled && UIApplication.shared.applicationState != .active {
            KeepAlive.shared.stop()
        }
    }

    private func notifyIfAway(_ job: Job) {
        guard UIApplication.shared.applicationState != .active else { return }
        let strings = BackgroundCheck.strings
        let title = job.status == "completed" ? (strings["readyNotification"] ?? "Transfert prêt à partager") : (job.error ?? strings["failed"] ?? "L’envoi a échoué.")
        Notifications.show(id: "upload-\(job.id)", title: title, body: job.title, path: job.transferId.map { "/transfers/\($0)" } ?? "/transfers", thread: nil)
    }

    // MARK: - Progress

    /// Bytes the server confirmed, plus the chunk in flight.
    func uploadedBytes(_ job: Job) -> Int64 {
        let confirmed = job.files.reduce(Int64(0)) { $0 + min($1.uploaded, $1.size) }
        let total = job.files.reduce(Int64(0)) { $0 + $1.size }
        return min(total, confirmed + (job.id == runningId ? inFlight : 0))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard task === self.task, let i = current() else { return }
        inFlight = totalBytesSent
        emit(jobs[i])
        LiveActivities.update(jobs[i], sent: uploadedBytes(jobs[i]))
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let i = current() else { return }
        jobs[i].notice = BackgroundCheck.strings["offline"]
        emit(jobs[i], force: true)
    }

    /// Sends the job to the page, in the shape of its own UploadJob.
    private func emit(_ job: Job, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) > 0.25 else { return }
        lastEmit = now
        let sent = uploadedBytes(job)
        let total = job.files.reduce(Int64(0)) { $0 + $1.size }
        let running = job.id == runningId
        if running, now.timeIntervalSince(lastTick) >= 0.8 {
            let instant = Double(max(0, sent - lastBytes)) / now.timeIntervalSince(lastTick)
            speed = speed.map { $0 * 0.7 + instant * 0.3 } ?? instant
            lastBytes = sent
            lastTick = now
        }
        let inFlightKey = running ? job.files.first(where: { $0.status == "uploading" })?.key : nil
        var payload: [String: Any] = [
            "id": job.id,
            "title": job.title,
            "status": job.status,
            "totalBytes": total,
            "uploadedBytes": sent,
            "startedAt": job.startedAt,
            "native": true,
            "files": job.files.map { file -> [String: Any] in
                var entry: [String: Any] = [
                    "key": file.key,
                    "name": file.name,
                    "size": file.size,
                    "type": file.type,
                    "uploaded": min(file.size, file.uploaded + (file.key == inFlightKey ? inFlight : 0)),
                    "status": file.status,
                ]
                entry["serverId"] = file.serverId
                entry["error"] = file.error
                return entry
            },
        ]
        payload["transferId"] = job.transferId
        payload["error"] = job.error
        payload["notice"] = job.notice
        if running, job.status == "uploading", let speed = speed {
            payload["speed"] = speed
            if speed > 1024 { payload["eta"] = Double(total - sent) / speed }
        }
        if let result = job.result, let object = try? JSONSerialization.jsonObject(with: result) {
            payload["result"] = object
        }
        WebViewController.shared.send(["type": "upload", "job": payload])
    }

    // MARK: - Helpers

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Digistban upload") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func request(_ method: String, _ path: String, json: [String: Any]? = nil, done: @escaping (Int, Data?) -> Void) {
        guard let url = URL(string: Uploader.api + path) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        Uploader.authorize(&request)
        if let json = json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        session.dataTask(with: request) { data, response, error in
            if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
            done((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }.resume()
    }

    private static func authorize(_ request: inout URLRequest) {
        request.setValue("1", forHTTPHeaderField: "X-Digistban")
        request.setValue(BackgroundCheck.language ?? "fr", forHTTPHeaderField: "X-Digistban-Lang")
        if let cookie = Keychain.read() { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
    }

    private static func read(_ url: URL, offset: Int64, length: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: length)
        } catch {
            return nil
        }
    }

    private static func object(_ data: Data?) -> [String: Any]? {
        guard let data = data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}
