import SafariServices
import UIKit
import UserNotifications
import WebKit

/// The whole app is digistban.com/help shown in a web view, so every update of
/// the server reaches the iPhone without installing a new IPA. The native side
/// adds what a browser cannot: launch transition, offline screen, downloads
/// opened in Quick Look, camera and microphone without repeated prompts,
/// haptics, icon badge and local notifications.
final class WebViewController: UIViewController {
    static let shared = WebViewController()

    static let host = "digistban.com"
    static let home = URL(string: "https://digistban.com/help/")!

    private var webView: WKWebView!
    private let splash = SplashView()
    private let offline = OfflineView()
    private let downloadPill = DownloadPill()
    private let bridge = Bridge()
    private let downloads = Downloads()
    /// iOS 26: the system tab bar over the page.
    private(set) var glassTabs: GlassTabs?
    /// Screen to open once the web app is listening (notification tap at launch, deep link).
    private var pendingPath: String?
    /// The web app has started and listens to native events.
    private var webReady = false
    /// A call answered on the iPhone's call screen, for the page to connect.
    private var pendingAnswer: [String: Any]?
    /// Files picked or shared before the page was listening.
    private var pendingFiles: [[String: Any]] = []
    /// Things to do once the page is ready (home screen quick actions).
    private var pendingActions: [() -> Void] = []
    private var started = false
    private var statusBarStyle: UIStatusBarStyle = .lightContent

    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }

    static func isAppHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == WebViewController.host || host == "www." + WebViewController.host
    }

    /// Pages of the app, and short share links (they redirect into it).
    static func isAppURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", isAppHost(url.host) else { return false }
        return url.path == "/help" || url.path.hasPrefix("/help/") || url.path.hasPrefix("/d/")
    }

    /// Path inside the web app ("/messages/…") for an app URL.
    static func appPath(of url: URL) -> String {
        var path = url.path
        if path.hasPrefix("/help") { path = String(path.dropFirst("/help".count)) }
        if path.isEmpty { path = "/" }
        if let query = url.query, !query.isEmpty { path += "?" + query }
        return path
    }

    // MARK: - Views

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .black
        view = root

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = "Mobile/15E148 DigistbanApp/\(Bridge.version)"
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Bridge.startScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: Bridge.viewportScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        content.add(bridge, name: "digistban")
        configuration.userContentController = content

        let webView = WKWebView(frame: root.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.underPageBackgroundColor = .black
        webView.scrollView.backgroundColor = .black
        // The page lays itself out under the status bar and home indicator (env(safe-area-inset-*)).
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        // The site turns screens back itself, like an app (it follows the finger and shows
        // the previous screen underneath); the web view's history swipe would show web pages.
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(iOS 16.4, *) {
            // Lets Safari's Web Inspector attach from a Mac, for debugging.
            webView.isInspectable = true
        }
        root.addSubview(webView)
        self.webView = webView

        if GlassTabs.available {
            let tabs = GlassTabs()
            tabs.install(in: self, above: webView)
            tabs.onSelect = { [weak self] path in self?.send(["type": "tab", "path": path]) }
            tabs.onInset = { [weak self] inset in self?.send(["type": "insets", "bottom": Double(inset)]) }
            glassTabs = tabs
        }

        offline.frame = root.bounds
        offline.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        offline.isHidden = true
        offline.onRetry = { [weak self] in self?.retry() }
        root.addSubview(offline)

        downloadPill.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(downloadPill)
        NSLayoutConstraint.activate([
            downloadPill.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
            downloadPill.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            downloadPill.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48),
            downloadPill.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        BackgroundDownloads.shared.onChange = { [weak self] in
            self?.downloadPill.refresh(Array(BackgroundDownloads.shared.active.values))
        }

        splash.frame = root.bounds
        splash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.addSubview(splash)

        bridge.controller = self
        downloads.presenter = self
        FilePicker.shared.onPicked = { [weak self] items in self?.deliverFiles(items, shared: false) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glassTabs?.reportInset()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        start(path: pendingPath)
        pendingPath = nil
        // Never leave the launch screen up for long: the web app has its own loading screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.hideSplash() }
    }

    private func start(path: String?) {
        var url = WebViewController.home
        if let path = path, path != "/", let target = URL(string: "https://\(WebViewController.host)/help\(path)") {
            url = target
        }
        started = true
        webReady = false
        webView.load(URLRequest(url: url))
    }

    private func retry() {
        offline.isHidden = true
        if webView.url == nil { start(path: nil) } else { webView.reload() }
    }

    private func hideSplash() {
        guard !splash.isHidden, splash.alpha > 0 else { return }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.splash.alpha = 0
            if !reduceMotion { self.splash.transform = CGAffineTransform(scaleX: 1.04, y: 1.04) }
        }, completion: { _ in
            self.splash.isHidden = true
            self.splash.transform = .identity
        })
    }

    // MARK: - Web app

    /// The web app has started: open what was waiting and report the native status.
    func webAppReady() {
        webReady = true
        offline.isHidden = true
        hideSplash()
        if let path = pendingPath {
            pendingPath = nil
            send(["type": "navigate", "url": path])
        }
        if let answer = pendingAnswer {
            pendingAnswer = nil
            send(answer)
        }
        pendingFiles.forEach { send($0) }
        pendingFiles.removeAll()
        Uploader.shared.broadcast()
        let actions = pendingActions
        pendingActions.removeAll()
        if !actions.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { actions.forEach { $0() } }
        }
        glassTabs?.resendInset()
        sendStatus()
        BackgroundCheck.saveSession()
    }

    /// Opens a screen of the web app ("/messages/…").
    func navigate(to path: String) {
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return }
        if webReady {
            send(["type": "navigate", "url": path])
        } else if !isViewLoaded || !started {
            pendingPath = path
        } else {
            // Still loading: start again directly on that screen.
            start(path: path)
        }
    }

    /// Answered on the call screen: open the conversation and let the page connect the call.
    func answer(callId: String, conversation: String, video: Bool) {
        let event: [String: Any] = ["type": "answer", "callId": callId, "video": video]
        navigate(to: "/messages/\(conversation)")
        if webReady { send(event) } else { pendingAnswer = event }
    }

    // MARK: - Downloads

    func presentDownloaded(_ file: URL) {
        whenReady { [weak self] in self?.downloads.present(file) }
    }

    func showDownloadError(_ message: String) {
        let alert = UIAlertController(title: NSLocalizedString("download.failed", comment: ""), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        topmost.present(alert, animated: true)
    }

    // MARK: - Files, quick actions, QR codes

    /// Files ready to send: the page adds them to "Envoyer" (shared from another app: it opens there).
    func deliverFiles(_ items: [Staging.Item], shared: Bool) {
        guard !items.isEmpty else { return }
        if shared { navigate(to: "/") }
        let event: [String: Any] = ["type": "files", "files": items.map { $0.json }, "shared": shared]
        if webReady { send(event) } else { pendingFiles.append(event) }
    }

    /// Runs now if the page is ready, otherwise as soon as it is.
    private func whenReady(_ action: @escaping () -> Void) {
        if webReady && view.window != nil { action() } else { pendingActions.append(action) }
    }

    func pickFiles(source: String? = nil) {
        whenReady { [weak self] in
            guard let self = self else { return }
            FilePicker.shared.present(from: self.topmost, source: source)
        }
    }

    func presentScanner() {
        whenReady { [weak self] in
            guard let self = self else { return }
            let scanner = QRScannerController()
            scanner.modalPresentationStyle = .fullScreen
            scanner.onCode = { [weak self] code in self?.handleScanned(code) }
            self.topmost.present(scanner, animated: true)
        }
    }

    /// A Digistban link opens in the app; anything else is shown first.
    private func handleScanned(_ code: String) {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), WebViewController.isAppURL(url) {
            navigate(to: WebViewController.appPath(of: url))
            return
        }
        let alert = UIAlertController(title: NSLocalizedString("scan.notDigistban", comment: ""), message: text, preferredStyle: .alert)
        if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            alert.addAction(UIAlertAction(title: NSLocalizedString("scan.open", comment: ""), style: .default) { [weak self] _ in self?.openOutside(url) })
        } else {
            alert.addAction(UIAlertAction(title: NSLocalizedString("scan.copy", comment: ""), style: .default) { _ in UIPasteboard.general.string = text })
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("common.cancel", comment: ""), style: .cancel))
        topmost.present(alert, animated: true)
    }

    /// Home screen quick actions (Info.plist UIApplicationShortcutItems).
    func perform(shortcut type: String) {
        switch type {
        case "com.digistban.app.send":
            navigate(to: "/")
            pickFiles()
        case "com.digistban.app.transfers":
            navigate(to: "/transfers")
        case "com.digistban.app.messages":
            navigate(to: "/messages")
        case "com.digistban.app.scan":
            presentScanner()
        default:
            break
        }
    }

    /// Files shared through the share extension, waiting for the app.
    func collectSharedFiles() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["share-inbox"])
        let items = Inbox.collect()
        if !items.isEmpty { deliverFiles(items, shared: true) }
    }

    func open(deepLink url: URL) {
        if url.isFileURL {
            // "Open in Digistban" from Files, Mail… (a copy in the app's Inbox folder).
            DispatchQueue.global(qos: .userInitiated).async {
                let item = Staging.adopt(url, move: true) ?? Staging.adopt(url)
                DispatchQueue.main.async { [weak self] in
                    if let item = item { self?.deliverFiles([item], shared: true) }
                }
            }
            return
        }
        if url.scheme?.lowercased() == "digistban", url.host == "share" {
            collectSharedFiles()
            return
        }
        if url.scheme?.lowercased() == "digistban", url.host == "download" {
            // The download activity was tapped: open the last file downloaded.
            if let file = BackgroundDownloads.shared.lastFile { presentDownloaded(file) }
            return
        }
        if url.scheme?.lowercased() == "digistban", url.host == "scan" {
            presentScanner()
            return
        }
        if url.scheme?.lowercased() == "digistban" {
            // digistban://d/abcd -> /d/abcd, digistban://messages/42 -> /messages/42
            var path = "/" + ((url.host ?? "") + url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let query = url.query, !query.isEmpty { path += "?" + query }
            navigate(to: path)
        } else if WebViewController.isAppURL(url) {
            navigate(to: WebViewController.appPath(of: url))
        }
    }

    func didReturnToForeground() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["app-closed"])
        if started && webView.url == nil {
            // The page was dropped while in the background (memory): load it again.
            start(path: nil)
            return
        }
        sendStatus()
        BackgroundCheck.saveSession()
    }

    func sendStatus() {
        Notifications.status { [weak self] value in
            self?.send([
                "type": "status",
                "notifications": value,
                "backgroundRefresh": BackgroundCheck.availability(),
                "microphone": MediaPermissions.status(.audio),
                "camera": MediaPermissions.status(.video),
                "reachable": KeepAlive.enabled,
            ])
        }
    }

    func applyTheme(dark: Bool, background: UIColor?) {
        statusBarStyle = dark ? .lightContent : .darkContent
        setNeedsStatusBarAppearanceUpdate()
        overrideUserInterfaceStyle = dark ? .dark : .light
        let color = background ?? (dark ? .black : .white)
        view.backgroundColor = color
        webView.backgroundColor = color
        webView.underPageBackgroundColor = color
        webView.scrollView.backgroundColor = color
    }

    /// Dispatches `digistban-native` on the page's window.
    func send(_ event: [String: Any]) {
        guard webReady,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('digistban-native', { detail: \(json) }))", completionHandler: nil)
    }

    // MARK: - Leaving the app

    /// SumUp's payment page (payment requests), in a sheet over the app. The page
    /// closes it once the server confirms the payment.
    private weak var paymentSheet: SFSafariViewController?

    func openPayment(_ url: URL) {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host == "sumup.com" || host.hasSuffix(".sumup.com") else { return }
        paymentSheet?.dismiss(animated: false)
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = .label
        safari.dismissButtonStyle = .close
        safari.modalPresentationStyle = .pageSheet
        safari.delegate = self
        paymentSheet = safari
        topmost.present(safari, animated: true)
        Diagnostics.note("pay-sheet-open")
    }

    func closePayment() {
        guard let sheet = paymentSheet else { return }
        paymentSheet = nil
        sheet.dismiss(animated: true) { [weak self] in self?.send(["type": "externalClosed"]) }
    }

    func openOutside(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        // SumUp's pages (payment, bank check) go in the payment sheet, which closes itself once paid.
        if scheme == "https", let host = url.host?.lowercased(), host == "sumup.com" || host.hasSuffix(".sumup.com") {
            openPayment(url)
            return
        }
        if scheme == "http" || scheme == "https" {
            let safari = SFSafariViewController(url: url)
            safari.preferredControlTintColor = .label
            safari.dismissButtonStyle = .close
            topmost.present(safari, animated: true)
        } else if UIApplication.shared.canOpenURL(url) || ["mailto", "tel", "sms", "facetime"].contains(scheme) {
            UIApplication.shared.open(url)
        }
    }

    /// Link opened in a new window (target="_blank", window.open).
    private func openFromPage(_ request: URLRequest) {
        guard let url = request.url else { return }
        if ["blob", "data"].contains(url.scheme?.lowercased() ?? "") {
            webView.startDownload(using: request) { [weak self] download in
                download.delegate = self?.downloads
            }
        } else if WebViewController.isAppURL(url) {
            if url.path.hasPrefix("/help/api/") {
                // A file (PDF opened in a new tab…): download it with the session, then preview it.
                webView.startDownload(using: request) { [weak self] download in
                    download.delegate = self?.downloads
                }
            } else {
                navigate(to: WebViewController.appPath(of: url))
            }
        } else {
            openOutside(url)
        }
    }

    private func pageFailed(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        // "Frame load interrupted": the navigation became a download.
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        // Once the web app runs, it handles connection problems itself.
        guard !webReady else { return }
        hideSplash()
        offline.show(message: nsError.localizedDescription)
    }
}

// MARK: - Navigation

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            // A file of Digistban: the system downloads it (goes on outside the app,
            // progress in the Dynamic Island). Caught before any request, so it counts once.
            if let url = navigationAction.request.url, url.scheme?.lowercased() == "https", WebViewController.isAppURL(url) {
                decisionHandler(.cancel)
                BackgroundDownloads.shared.start(url: url)
                return
            }
            decisionHandler(.download)
            return
        }
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        guard let frame = navigationAction.targetFrame else {
            // New window (target="_blank", window.open): handled here, the app has a single window.
            decisionHandler(.cancel)
            openFromPage(navigationAction.request)
            return
        }
        if ["about", "blob", "data"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        if WebViewController.isAppURL(url) {
            // A plain link to another screen: move inside the running app instead of reloading it.
            if frame.isMainFrame, webReady, navigationAction.navigationType == .linkActivated, !url.path.hasPrefix("/help/api/") {
                decisionHandler(.cancel)
                navigate(to: WebViewController.appPath(of: url))
                return
            }
            decisionHandler(.allow)
            return
        }
        // Frames inside a page (document previews) stay where they are.
        if !frame.isMainFrame {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        openOutside(url)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new page: it says when its app is listening (Bridge "ready").
        webReady = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        offline.isHidden = true
        // The page shows its own launch screen, identical to this one: hand over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.hideSplash() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS reclaimed the page's memory: reload instead of showing a blank screen.
        webReady = false
        if webView.url != nil { webView.reload() } else { start(path: nil) }
    }
}

// MARK: - Page requests

extension WebViewController: SFSafariViewControllerDelegate {
    /// Closed by hand (paid or not): the page asks the server where the payment stands.
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        guard controller === paymentSheet else { return }
        paymentSheet = nil
        send(["type": "externalClosed"])
    }
}

extension WebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        openFromPage(navigationAction.request)
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        topmost.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("common.cancel", comment: ""), style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        topmost.present(alert, animated: true)
    }

    /// Calls and voice notes: iOS asks once for the microphone and camera, the page does not ask again.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.protocol == "https" && WebViewController.isAppHost(origin.host) ? .grant : .deny)
    }
}

extension UIViewController {
    /// The controller currently on screen, to present over it.
    var topmost: UIViewController {
        if let presented = presentedViewController, !presented.isBeingDismissed { return presented.topmost }
        return self
    }
}
