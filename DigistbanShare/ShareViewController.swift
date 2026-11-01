import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// "Digistban" in the share sheet of Photos, Files and other apps. The shared
/// items are copied to the folder shared with the app (App Group), then the
/// app opens on "Envoyer" with them, ready to send.
final class ShareViewController: UIViewController {
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let icon = UIImageView(image: UIImage(systemName: "paperplane.circle.fill"))
    private let titleLabel = UILabel()
    private let detail = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let primary = UIButton(type: .system)
    private let secondary = UIButton(type: .system)
    private var ready = false

    private final class Collected {
        var count = 0
        var bytes: Int64 = 0
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        trace(AppGroup.inbox == nil ? "share-open-nogroup" : "share-open")
        layout()
        collect()
    }

    /// Same diagnostics as the app (nginx access log), nothing personal.
    private func trace(_ step: String) {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        guard let url = URL(string: "https://digistban.com/help/api/health?app=\(step)&b=\(build)&s=ext") else { return }
        URLSession.shared.dataTask(with: url).resume()
    }

    private func layout() {
        card.layer.cornerRadius = 28
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        icon.tintColor = .label
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        titleLabel.text = NSLocalizedString("share.title", comment: "")
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textAlignment = .center
        detail.text = NSLocalizedString("share.preparing", comment: "")
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = .secondaryLabel
        detail.textAlignment = .center
        detail.numberOfLines = 0
        spinner.startAnimating()

        var primaryStyle = UIButton.Configuration.filled()
        primaryStyle.title = NSLocalizedString("share.open", comment: "")
        primaryStyle.baseBackgroundColor = .label
        primaryStyle.baseForegroundColor = .systemBackground
        primaryStyle.cornerStyle = .capsule
        primaryStyle.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 22, bottom: 13, trailing: 22)
        primary.configuration = primaryStyle
        primary.isEnabled = false
        primary.addTarget(self, action: #selector(openApp), for: .touchUpInside)

        var secondaryStyle = UIButton.Configuration.plain()
        secondaryStyle.title = NSLocalizedString("share.cancel", comment: "")
        secondaryStyle.baseForegroundColor = .secondaryLabel
        secondary.configuration = secondaryStyle
        secondary.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, detail, spinner, primary, secondary])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.setCustomSpacing(18, after: spinner)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -14),
            primary.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    /// Copies every shared item into Inbox/.<batch>/<id>/<name>, then renames the batch (ready for the app).
    private func collect() {
        guard let inbox = AppGroup.inbox else {
            spinner.stopAnimating()
            detail.text = NSLocalizedString("share.unavailable", comment: "")
            primary.isHidden = true
            return
        }
        let id = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased())"
        let writing = inbox.appendingPathComponent(".\(id)", isDirectory: true)
        let batch = inbox.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: writing, withIntermediateDirectories: true)

        let providers = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? []).flatMap { $0.attachments ?? [] }
        let collected = Collected()
        let group = DispatchGroup()
        for provider in providers {
            let types = provider.registeredTypeIdentifiers
            let media = types.first { identifier in
                guard let kind = UTType(identifier) else { return false }
                return kind.conforms(to: .image) || kind.conforms(to: .movie)
            }
            let file = types.first { UTType($0)?.conforms(to: .data) == true }
            guard let chosen = media ?? file ?? types.first else { continue }
            let suggested = provider.suggestedName
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: chosen) { url, _ in
                // The file disappears when this block returns: copy it now.
                let size: Int64 = {
                    guard let url = url else { return -1 }
                    var name = url.lastPathComponent
                    if let suggested = suggested, !suggested.isEmpty {
                        name = url.pathExtension.isEmpty || suggested.hasSuffix(".\(url.pathExtension)") ? suggested : "\(suggested).\(url.pathExtension)"
                    }
                    let folder = writing.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
                    let target = folder.appendingPathComponent(AppGroup.safeName(name))
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: target)
                    } catch {
                        return -1
                    }
                    let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
                    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                }()
                DispatchQueue.main.async {
                    if size >= 0 {
                        collected.count += 1
                        collected.bytes += size
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            self.spinner.isHidden = true
            guard collected.count > 0, (try? FileManager.default.moveItem(at: writing, to: batch)) != nil else {
                try? FileManager.default.removeItem(at: writing)
                self.detail.text = NSLocalizedString("share.nothing", comment: "")
                return
            }
            self.trace("share-ready-\(min(collected.count, 99))")
            let size = ByteCountFormatter.string(fromByteCount: collected.bytes, countStyle: .file)
            self.detail.text = String(format: NSLocalizedString("share.ready", comment: ""), collected.count, size)
            self.primary.isEnabled = true
            self.ready = true
        }
    }

    @objc private func openApp() {
        guard ready, let url = URL(string: "digistban://share") else { return }
        // Share extensions have no official way to open their app: walk up to the
        // application object and call openURL:options:completionHandler: on it
        // dynamically. If iOS refuses, the notification below opens the app.
        typealias OpenURL = @convention(c) (NSObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current !== self, current.responds(to: selector), let method = current.method(for: selector) {
                let open = unsafeBitCast(method, to: OpenURL.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                break
            }
            responder = current.next
        }
        remind()
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// "Touch to send your files": opens the app if it did not open by itself.
    private func remind() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("share.reminderTitle", comment: "")
        content.body = NSLocalizedString("share.reminderBody", comment: "")
        content.userInfo = ["path": "/"]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "share-inbox", content: content, trigger: trigger)) { _ in }
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
