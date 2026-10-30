import Network
import UIKit

/// Same picture as the launch screen (Info.plist UILaunchScreen), kept until the
/// page shows its own, identical loading screen.
final class SplashView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(named: "LaunchBackground") ?? .black
        let logo = UIImageView(image: UIImage(named: "LaunchLogo"))
        logo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Shown when the app cannot reach digistban.com at launch. Tries again by
/// itself as soon as the network comes back.
final class OfflineView: UIView {
    var onRetry: (() -> Void)?
    private let detail = UILabel()
    private let monitor = NWPathMonitor()
    private var lastStatus: NWPath.Status?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        let icon = UIImageView(image: UIImage(systemName: "wifi.slash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)))
        icon.tintColor = UIColor(white: 1, alpha: 0.9)
        icon.contentMode = .center
        let badge = UIView()
        badge.backgroundColor = UIColor(white: 1, alpha: 0.08)
        badge.layer.cornerRadius = 24
        badge.layer.cornerCurve = .continuous
        badge.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)

        let title = UILabel()
        title.text = NSLocalizedString("offline.title", comment: "")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = .white
        title.textAlignment = .center
        title.numberOfLines = 0

        let message = UILabel()
        message.text = NSLocalizedString("offline.message", comment: "")
        message.font = .systemFont(ofSize: 16)
        message.textColor = UIColor(white: 1, alpha: 0.65)
        message.textAlignment = .center
        message.numberOfLines = 0

        detail.font = .systemFont(ofSize: 13)
        detail.textColor = UIColor(white: 1, alpha: 0.4)
        detail.textAlignment = .center
        detail.numberOfLines = 0

        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("offline.retry", comment: "")
        configuration.baseBackgroundColor = .white
        configuration.baseForegroundColor = .black
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 26, bottom: 13, trailing: 26)
        let retry = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            Haptics.play("light")
            self?.onRetry?()
        })

        let stack = UIStackView(arrangedSubviews: [badge, title, message, retry, detail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.setCustomSpacing(22, after: badge)
        stack.setCustomSpacing(26, after: message)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 84),
            badge.heightAnchor.constraint(equalToConstant: 84),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor, constant: -16),
        ])

        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.networkChanged(path.status) }
        }
        monitor.start(queue: DispatchQueue(label: "com.digistban.app.network"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        monitor.cancel()
    }

    func show(message: String) {
        detail.text = message
        guard isHidden else { return }
        alpha = 0
        isHidden = false
        UIView.animate(withDuration: 0.25) { self.alpha = 1 }
    }

    private func networkChanged(_ status: NWPath.Status) {
        defer { lastStatus = status }
        if status == .satisfied, lastStatus != nil, lastStatus != .satisfied, !isHidden {
            onRetry?()
        }
    }
}
