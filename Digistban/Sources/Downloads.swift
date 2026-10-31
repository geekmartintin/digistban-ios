import QuickLook
import UIKit
import WebKit

/// Files downloaded from the app open in Quick Look (photos, videos, PDF,
/// documents…), whose share button saves them to Files or Photos. Other files
/// go straight to the share sheet.
final class Downloads: NSObject, WKDownloadDelegate, QLPreviewControllerDataSource {
    weak var presenter: UIViewController?
    private var targets: [ObjectIdentifier: URL] = [:]
    private var previewed: [URL] = []

    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Keeps a name usable as a file name.
    private static func fileName(_ suggested: String) -> String {
        let cleaned = suggested
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\0"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Digistban" : cleaned
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        // One folder per download: two files with the same name never collide.
        let folder = Downloads.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            completionHandler(nil)
            return
        }
        let target = folder.appendingPathComponent(Downloads.fileName(suggestedFilename))
        targets[ObjectIdentifier(download)] = target
        Haptics.play("light")
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = targets.removeValue(forKey: ObjectIdentifier(download)) else { return }
        Haptics.play("success")
        present(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        targets.removeValue(forKey: ObjectIdentifier(download))
        Haptics.play("error")
        guard let presenter = presenter?.topmost else { return }
        let alert = UIAlertController(title: NSLocalizedString("download.failed", comment: ""), message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }

    func present(_ file: URL) {
        guard let presenter = presenter?.topmost else { return }
        if QLPreviewController.canPreview(file as NSURL) {
            previewed = [file]
            let preview = QLPreviewController()
            preview.dataSource = self
            presenter.present(preview, animated: true)
        } else {
            let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            if let popover = share.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 80, width: 1, height: 1)
            }
            presenter.present(share, animated: true)
        }
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewed.count
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        previewed[index] as NSURL
    }

    /// Downloads older than a day are no longer needed (iOS also empties this folder by itself).
    static func cleanUp() {
        let limit = Date().addingTimeInterval(-86400)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < limit { try? FileManager.default.removeItem(at: entry) }
        }
    }
}
