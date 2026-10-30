import AVFoundation
import UIKit

/// Full-screen camera that reads a QR code (a Digistban link shown on another
/// screen) and hands its text back.
final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let capture = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private let frameGuide = UIView()
    private let hint = UILabel()
    private var handled = false

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        frameGuide.layer.borderColor = UIColor.white.cgColor
        frameGuide.layer.borderWidth = 3
        frameGuide.layer.cornerRadius = 28
        frameGuide.layer.cornerCurve = .continuous
        frameGuide.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frameGuide)

        hint.text = NSLocalizedString("scan.hint", comment: "")
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 17, weight: .semibold)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        var close = UIButton.Configuration.filled()
        close.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        close.baseBackgroundColor = UIColor(white: 1, alpha: 0.18)
        close.baseForegroundColor = .white
        close.cornerStyle = .capsule
        close.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        let closeButton = UIButton(configuration: close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        closeButton.accessibilityLabel = NSLocalizedString("scan.close", comment: "")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            frameGuide.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameGuide.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            frameGuide.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.68),
            frameGuide.heightAnchor.constraint(equalTo: frameGuide.widthAnchor),
            hint.topAnchor.constraint(equalTo: frameGuide.bottomAnchor, constant: 28),
            hint.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -12),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { [weak self] in
                    if granted { self?.configure() } else { self?.showDenied() }
                }
            }
        default:
            showDenied()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = capture
        DispatchQueue.global(qos: .userInitiated).async {
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              capture.canAddInput(input) else {
            showDenied()
            return
        }
        capture.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard capture.canAddOutput(output) else { return }
        capture.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: capture)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        preview = layer

        let session = capture
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func showDenied() {
        hint.text = NSLocalizedString("scan.denied", comment: "")
        var settings = UIButton.Configuration.filled()
        settings.title = NSLocalizedString("scan.settings", comment: "")
        settings.baseBackgroundColor = .white
        settings.baseForegroundColor = .black
        settings.cornerStyle = .capsule
        let button = UIButton(configuration: settings, primaryAction: UIAction { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        })
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 20),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !handled, let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        handled = true
        Haptics.play("success")
        dismiss(animated: true) { [weak self] in self?.onCode?(code) }
    }
}

/// Files shared from other apps through the share extension, waiting in the
/// folder shared with it (AppGroup.inbox): moved into the app's own folder.
enum Inbox {
    static func collect() -> [Staging.Item] {
        guard let inbox = AppGroup.inbox,
              let batches = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return [] }
        try? FileManager.default.createDirectory(at: Staging.folder, withIntermediateDirectories: true)
        var items: [Staging.Item] = []
        // Names starting with a dot are still being written by the extension.
        for batch in batches.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !batch.lastPathComponent.hasPrefix(".") {
            let folders = (try? FileManager.default.contentsOfDirectory(at: batch, includingPropertiesForKeys: nil)) ?? []
            for folder in folders {
                let id = folder.lastPathComponent
                let target = Staging.folder.appendingPathComponent(id, isDirectory: true)
                if (try? FileManager.default.moveItem(at: folder, to: target)) != nil, let item = Staging.item(id: id) {
                    items.append(item)
                }
            }
            try? FileManager.default.removeItem(at: batch)
        }
        return items
    }
}
