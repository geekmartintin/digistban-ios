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
    private let bridge = Bridge()
    private let downloads = Downloads()
    /// Screen to open once the web app is listening (notification tap at launch, deep link).
    private var pendingPath: String?
    /// The web app has started and listens to native events.
    private var webReady = false
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
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(iOS 16.4, *) {
            // Lets Safari's Web Inspector attach from a Mac, for debugging.
            webView.isInspectable = true
        }
        root.addSubview(webView)
        self.webView = webView

        offline.frame = root.bounds
        offline.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        offline.isHidden = true
        offline.onRetry = { [weak self] in self?.retry() }
        root.addSubview(offline)

        splash.frame = root.bounds
        splash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.addSubview(splash)

        bridge.controller = self
        downloads.presenter = self
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

    func open(deepLink url: URL) {
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

    private func openOutside(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
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
