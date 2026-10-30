import UIKit

/// iOS 26: the system tab bar (Liquid Glass) floats over the page, which then
/// hides its own. A UITabBarController gives the real thing (glass, lens that
/// follows the finger, badge); its four screens stay empty and transparent:
/// the page underneath shows the content and is told which tab was chosen.
final class GlassTabs: NSObject, UITabBarControllerDelegate {
    static var available: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private static let paths = ["/", "/transfers", "/messages", "/reglages"]
    private static let symbols = [("paperplane", "paperplane.fill"), ("archivebox", "archivebox.fill"), ("bubble.left", "bubble.left.fill")]

    private let controller = UITabBarController()
    private let container = PassThroughView()
    private var visible = false
    private var initials = ""
    private var lastInset: CGFloat = -1
    /// A tab was tapped: the page's path for it.
    var onSelect: ((String) -> Void)?
    /// Height the bar covers at the bottom of the screen, for the page's own margin.
    var onInset: ((CGFloat) -> Void)?

    func install(in parent: UIViewController, above content: UIView) {
        controller.viewControllers = GlassTabs.paths.map { _ in
            let screen = UIViewController()
            screen.view.backgroundColor = .clear
            screen.view.isUserInteractionEnabled = false
            return screen
        }
        controller.delegate = self
        controller.view.backgroundColor = .clear
        controller.tabBar.tintColor = .label
        for (index, item) in (controller.viewControllers ?? []).enumerated() where index < GlassTabs.symbols.count {
            item.tabBarItem.image = UIImage(systemName: GlassTabs.symbols[index].0)
            item.tabBarItem.selectedImage = UIImage(systemName: GlassTabs.symbols[index].1)
        }
        setProfile(initials: "")

        parent.addChild(controller)
        container.frame = parent.view.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.frame = container.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(controller.view)
        container.tabBar = controller.tabBar
        container.content = controller.view
        parent.view.insertSubview(container, aboveSubview: content)
        controller.didMove(toParent: parent)
        setHidden(true, animated: false)
    }

    /// The page's state: whether the menu shows, the current tab, unread count, labels.
    func apply(visible: Bool, active: Int?, unread: Int, initials: String, labels: [String]) {
        let items = (controller.viewControllers ?? []).map { $0.tabBarItem }
        for (index, item) in items.enumerated() where index < labels.count {
            item?.title = labels[index]
        }
        if items.count > 2 {
            items[2]?.badgeValue = unread > 0 ? (unread > 99 ? "99+" : String(unread)) : nil
        }
        if initials != self.initials { setProfile(initials: initials) }
        if let active = active, active >= 0, active < items.count, active != controller.selectedIndex {
            controller.selectedIndex = active
        }
        if visible != self.visible { setHidden(!visible, animated: true) }
    }

    /// Reports the bar's height when it changes (layout, rotation, shown or hidden).
    func reportInset() {
        guard let view = container.superview else { return }
        let inset = visible ? max(0, view.bounds.height - controller.tabBar.frame.minY) : 0
        guard abs(inset - lastInset) > 0.5 else { return }
        lastInset = inset
        onInset?(inset)
    }

    /// Sends the last height again (the page reloaded).
    func resendInset() {
        lastInset = -1
        reportInset()
    }

    private func setHidden(_ hidden: Bool, animated: Bool) {
        visible = !hidden
        if #available(iOS 18.0, *) {
            controller.setTabBarHidden(hidden, animated: animated)
        } else {
            controller.tabBar.isHidden = hidden
        }
        container.isHidden = false
        DispatchQueue.main.async { [weak self] in self?.reportInset() }
    }

    /// Profile tab: the account's initials in a circle, like the page's avatar.
    private func setProfile(initials: String) {
        self.initials = initials
        guard let item = controller.viewControllers?.last?.tabBarItem else { return }
        if initials.isEmpty {
            item.image = UIImage(systemName: "person.crop.circle")
            item.selectedImage = UIImage(systemName: "person.crop.circle.fill")
            return
        }
        let size = CGSize(width: 26, height: 26)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.black.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)).fill()
            let text = String(initials.prefix(2)).uppercased() as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: UIColor.black]
            let textSize = text.size(withAttributes: attributes)
            // The letters are cut out of the disc, so the image tints like a symbol.
            context.cgContext.setBlendMode(.clear)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }.withRenderingMode(.alwaysTemplate)
        item.image = image
        item.selectedImage = image
    }

    // MARK: - UITabBarControllerDelegate

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        Haptics.play("selection")
        let index = tabBarController.selectedIndex
        guard index >= 0, index < GlassTabs.paths.count else { return }
        onSelect?(GlassTabs.paths[index])
    }
}

/// Lets touches through to the page except on the tab bar.
final class PassThroughView: UIView {
    weak var tabBar: UIView?
    weak var content: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event), hit !== self, hit !== content else { return nil }
        var view: UIView? = hit
        while let current = view, current !== self {
            if current === tabBar { return hit }
            // The (empty) screens of the tabs: the page is underneath.
            if String(describing: type(of: current)).contains("TransitionView") { return nil }
            view = current.superview
        }
        // Anything else of the bar that is not a descendant of `tabBar` (floating parts).
        return hit
    }
}
