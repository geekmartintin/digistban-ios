import AVFoundation
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Files to send are copied into the app's own folder (Outgoing/<id>/<name>),
/// so they can be sent in the background and after a restart.
enum Staging {
    struct Item {
        let id: String
        let url: URL
        let name: String
        let size: Int64
        let type: String

        var json: [String: Any] { ["id": id, "name": name, "size": size, "type": type] }
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Outgoing", isDirectory: true)
    }

    /// Copies (or moves) a file into its own new folder.
    static func adopt(_ source: URL, name: String? = nil, move: Bool = false) -> Item? {
        let id = UUID().uuidString.lowercased()
        var directory = folder.appendingPathComponent(id, isDirectory: true)
        let target = directory.appendingPathComponent(AppGroup.safeName(name ?? source.lastPathComponent))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if move {
                try FileManager.default.moveItem(at: source, to: target)
            } else {
                try FileManager.default.copyItem(at: source, to: target)
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return item(id: id)
    }

    static func item(id: String) -> Item? {
        let directory = folder.appendingPathComponent(id, isDirectory: true)
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.first else { return nil }
        let url = directory.appendingPathComponent(name)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return Item(id: id, url: url, name: name, size: size, type: type)
    }

    /// A small JPEG of a photo or video (data: URL), for the page's file list.
    /// Slow enough on big files to be made off the main thread.
    static func thumbnail(of item: Item, side: CGFloat = 160) -> String? {
        guard let kind = UTType(filenameExtension: item.url.pathExtension) else { return nil }
        var picture: CGImage?
        if kind.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithURL(item.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ] as CFDictionary)
        } else if kind.conforms(to: .movie) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: side, height: side)
            let done = DispatchSemaphore(value: 0)
            generator.generateCGImageAsynchronously(for: CMTime(seconds: 0.3, preferredTimescale: 600)) { image, _, _ in
                picture = image
                done.signal()
            }
            _ = done.wait(timeout: .now() + 3)
        }
        guard let picture, let data = UIImage(cgImage: picture).jpegData(compressionQuality: 0.7) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id, isDirectory: true))
    }

    /// Files chosen but never sent are dropped after two days.
    static func cleanUp(keeping ids: Set<String>) {
        let limit = Date().addingTimeInterval(-2 * 86400)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for entry in entries where !ids.contains(entry.lastPathComponent) {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            if created < limit { try? FileManager.default.removeItem(at: entry) }
        }
    }
}

/// "Add files" in the app: Photos, Files, or a scanned document.
final class FilePicker: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate, VNDocumentCameraViewControllerDelegate {
    static let shared = FilePicker()

    /// Files ready to send (on the main queue).
    var onPicked: (([Staging.Item]) -> Void)?

    private final class Collected {
        var items: [Staging.Item] = []
    }

    func present(from presenter: UIViewController, source: String? = nil) {
        switch source {
        case "photos": photos(presenter)
        case "files": files(presenter)
        case "scan": scan(presenter)
        default:
            let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: NSLocalizedString("pick.photos", comment: ""), style: .default) { [weak self] _ in self?.photos(presenter) })
            sheet.addAction(UIAlertAction(title: NSLocalizedString("pick.files", comment: ""), style: .default) { [weak self] _ in self?.files(presenter) })
            if VNDocumentCameraViewController.isSupported {
                sheet.addAction(UIAlertAction(title: NSLocalizedString("pick.scan", comment: ""), style: .default) { [weak self] _ in self?.scan(presenter) })
            }
            sheet.addAction(UIAlertAction(title: NSLocalizedString("common.cancel", comment: ""), style: .cancel))
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            }
            presenter.present(sheet, animated: true)
        }
    }

    private func photos(_ presenter: UIViewController) {
        // No access to the whole library is needed: the picker runs outside the app.
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    private func files(_ presenter: UIViewController) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    private func scan(_ presenter: UIViewController) {
        let camera = VNDocumentCameraViewController()
        camera.delegate = self
        presenter.present(camera, animated: true)
    }

    // MARK: - Photos

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        let collected = Collected()
        let group = DispatchGroup()
        for result in results {
            let provider = result.itemProvider
            let types = provider.registeredTypeIdentifiers
            let type = types.first { identifier in
                guard let kind = UTType(identifier) else { return false }
                return kind.conforms(to: .image) || kind.conforms(to: .movie)
            } ?? types.first
            guard let chosen = type else { continue }
            let suggested = provider.suggestedName
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: chosen) { url, _ in
                // The file disappears when this block returns: copy it now.
                let item: Staging.Item? = {
                    guard let url = url else { return nil }
                    var name = url.lastPathComponent
                    if let suggested = suggested, !suggested.isEmpty {
                        name = url.pathExtension.isEmpty ? suggested : "\(suggested).\(url.pathExtension)"
                    }
                    return Staging.adopt(url, name: name)
                }()
                DispatchQueue.main.async {
                    if let item = item { collected.items.append(item) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.onPicked?(collected.items)
        }
    }

    // MARK: - Files

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let items = urls.compactMap { Staging.adopt($0, move: true) }
            DispatchQueue.main.async { [weak self] in self?.onPicked?(items) }
        }
    }

    // MARK: - Document scanner

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        controller.dismiss(animated: true)
        guard scan.pageCount > 0 else { return }
        let first = scan.imageOfPage(at: 0)
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.size)).pdfData { context in
            for index in 0..<scan.pageCount {
                let image = scan.imageOfPage(at: index)
                let page = CGRect(origin: .zero, size: image.size)
                context.beginPage(withBounds: page, pageInfo: [:])
                image.draw(in: page)
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let name = "\(NSLocalizedString("pick.scanName", comment: "")) \(formatter.string(from: Date())).pdf"
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        guard (try? data.write(to: temporary)) != nil, let item = Staging.adopt(temporary, name: name, move: true) else { return }
        onPicked?([item])
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        controller.dismiss(animated: true)
    }
}
