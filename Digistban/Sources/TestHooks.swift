import Foundation

/// Launch arguments used by the simulator tests (.github/workflows/simulator.yml,
/// DigistbanUITests). Never passed by iOS itself; without them nothing changes.
enum TestHooks {
    private static let arguments = ProcessInfo.processInfo.arguments

    private static func value(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Screen to open at launch ("/login").
    static var startPath: String? { value("-DigistbanTestPath") }

    /// Scripts added to the page for a test.
    static var userScripts: [String] {
        var scripts: [String] = []
        if arguments.contains("-DigistbanTestFakeLogin") { scripts.append(fakeLogin) }
        if arguments.contains("-DigistbanTestFps") { scripts.append(framesProbe) }
        // A script of the UI test itself (rendering checks in the real web view).
        if let script = ProcessInfo.processInfo.environment["DIGISTBAN_TEST_SCRIPT"] { scripts.append(script) }
        return scripts
    }

    /// Starts a download (photographed in the Dynamic Island), and pauses it after a while.
    static func run() {
        guard let link = value("-DigistbanTestDownload"), let url = URL(string: link) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            BackgroundDownloads.shared.start(url: url)
        }
        if let delay = value("-DigistbanTestPauseAfter").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4 + delay) {
                guard let job = BackgroundDownloads.shared.active.keys.first else { return }
                BackgroundDownloads.shared.control(job: job, action: "pause")
            }
        }
    }

    /// Sign-in without e-mail: the code screen opens for any address, and the
    /// code typed comes back as the error "TEST-VERIFY-<code>" (nothing reaches the server).
    private static let fakeLogin = """
    (function () {
      var original = window.fetch.bind(window);
      function reply(status, body) {
        return Promise.resolve(new Response(JSON.stringify(body), { status: status, headers: { 'Content-Type': 'application/json' } }));
      }
      window.fetch = function (input, init) {
        var url = typeof input === 'string' ? input : input.url;
        if (url.indexOf('/api/auth/start') >= 0 || url.indexOf('/api/auth/request') >= 0) {
          return reply(202, { status: 'code', challengeId: 'ui-test', email: 'test@example.com', codeExpiresAt: new Date(Date.now() + 600000).toISOString(), delivery: 'accepted', resendAfterSeconds: 60 });
        }
        if (url.indexOf('/api/auth/challenge/') >= 0) return reply(200, { problem: null });
        if (url.indexOf('/api/auth/verify') >= 0) {
          var code = '';
          try { code = JSON.parse((init && init.body) || '{}').code || ''; } catch (e) {}
          return reply(400, { error: { code: 'invalid_code', message: 'TEST-VERIFY-' + code } });
        }
        return original(input, init);
      };
    })();
    """

    /// Frame timing every 4 s, as a diagnostic trace: frames drawn, 95th percentile
    /// of the frame time, frames over 34 ms (a visible stutter).
    private static let framesProbe = """
    (function () {
      var frames = [], last = performance.now();
      function tick(now) { frames.push(now - last); last = now; requestAnimationFrame(tick); }
      requestAnimationFrame(tick);
      setInterval(function () {
        var list = frames.splice(0);
        if (!list.length) return;
        var sorted = list.slice().sort(function (a, b) { return a - b; });
        var p95 = Math.round(sorted[Math.floor(sorted.length * 0.95)]);
        var long = list.filter(function (value) { return value > 34; }).length;
        var page = location.pathname.replace(/[^a-z]/gi, '').slice(0, 12) || 'home';
        window.webkit.messageHandlers.digistban.postMessage({ type: 'diag', event: 'fps-' + page + '-n' + list.length + '-p' + p95 + '-l' + long });
      }, 4000);
    })();
    """
}
