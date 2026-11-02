import XCTest

/// Run in the iOS Simulator by .github/workflows/simulator.yml. Screenshots are
/// kept as attachments; frame timings go to the server log as "web-fps-…" traces.
final class DigistbanUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The code field is one iOS can fill (AutoFill skips hidden fields), and six
    /// digits typed in it sign in at once (no server: TestHooks fakes the answers).
    func testOneTimeCodeField() {
        let app = XCUIApplication()
        app.launchArguments = ["-DigistbanTestFakeLogin", "-DigistbanTestPath", "/login"]
        app.launch()
        let email = app.webViews.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 60), "e-mail field")
        email.tap()
        email.typeText("test@example.com\n")
        let code = app.webViews.textFields.matching(NSPredicate(format: "label CONTAINS[c] %@", "digit")).firstMatch
        // The shared simulator can be slow to switch screens: a long wait, not a failure.
        XCTAssertTrue(code.waitForExistence(timeout: 45), "code field")
        sleep(1)
        shot("1-code-screen")
        XCTAssertTrue(code.isHittable, "the code field is visible to iOS")
        code.tap()
        code.typeText("123456")
        let sent = app.webViews.staticTexts["TEST-VERIFY-123456"]
        XCTAssertTrue(sent.waitForExistence(timeout: 15), "six digits sent the code by themselves")
        shot("2-code-sent")
    }

    /// Pause and resume from the expanded Dynamic Island and from the Lock Screen.
    func testLiveActivityButtons() {
        let app = XCUIApplication()
        app.launchArguments = ["-DigistbanTestDownload", "https://proof.ovh.net/files/10Gb.dat"]
        app.launch()
        sleep(12)
        XCUIDevice.shared.press(.home)
        sleep(4)
        shot("3-island-running")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // A long press on the island opens it, with its buttons.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.045)).press(forDuration: 1.5)
        sleep(2)
        shot("4-island-expanded")
        let pause = springboard.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 6), "Pause button in the island")
        if pause.exists { pause.tap() }
        sleep(5)
        shot("5-island-after-pause")
        // Lock, then wake: the Lock Screen shows the activity and its buttons.
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(3)
        shot("6-lock-screen-paused")
        let resume = springboard.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 6), "Resume button on the Lock Screen")
        if resume.exists { resume.tap() }
        sleep(8)
        shot("7-lock-screen-resumed")
    }

    /// Scrolling and moving between screens while the page reports its frame timing.
    func testFrameTiming() {
        let app = XCUIApplication()
        app.launchArguments = ["-DigistbanTestFps"]
        app.launch()
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        sleep(8)
        for _ in 0..<4 {
            page.swipeUp(velocity: .fast)
            page.swipeDown(velocity: .fast)
        }
        sleep(4)
        shot("8-frames")
        sleep(5)
    }

    /// The code screen as it first appears (no tap, which redraws it), once per
    /// style variant applied from the start; the variant's name follows the title.
    func testCodeFieldFirstFrame() {
        let variants = [
            ("P0", ""),
            ("P4", "main{overflow:visible!important}html,body{overflow-x:clip!important}"),
            ("P5", "main{overflow:visible!important}html,body{overflow-x:hidden!important}"),
        ]
        for (name, css) in variants {
            let app = XCUIApplication()
            app.launchArguments = ["-DigistbanTestFakeLogin", "-DigistbanTestPath", "/login"]
            app.launchEnvironment["DIGISTBAN_TEST_SCRIPT"] = """
            document.addEventListener('DOMContentLoaded', function () {
              var style = document.createElement('style');
              style.textContent = "h1::after{content:' \(name)'}\(css)";
              document.head.appendChild(style);
            });
            """
            app.launch()
            let email = app.webViews.textFields.firstMatch
            XCTAssertTrue(email.waitForExistence(timeout: 60), "e-mail field")
            email.tap()
            email.typeText("test@example.com\n")
            let code = app.webViews.textFields.matching(NSPredicate(format: "label CONTAINS[c] %@", "digit")).firstMatch
            XCTAssertTrue(code.waitForExistence(timeout: 45), "code field")
            sleep(1)
            shot("13-\(name)-first")
            sleep(4)
            shot("13-\(name)-later")
            app.terminate()
        }
    }

    /// The send page and its options, with the switches, as the page cycles
    /// through style variants every 3 s (named in a yellow badge).
    func testSendOptionsRendering() {
        let app = XCUIApplication()
        app.launchArguments = ["-DigistbanTestPath", "/"]
        app.launchEnvironment["DIGISTBAN_TEST_SCRIPT"] = Self.fakeSession + Self.switchVariants
        app.launch()
        sleep(12)
        for index in 0..<7 {
            shot("12-switches-\(index)")
            sleep(3)
        }
    }

    /// Shared by both scripts: a style element, a badge naming the variant, and
    /// the clipping-related styles of the element's ancestors.
    private static let labTools = """
    window.__lab = function (target, variants, onStep) {
      var style = document.createElement('style');
      document.head.appendChild(style);
      var badge = document.createElement('div');
      badge.setAttribute('style', 'position:fixed;left:6px;top:150px;right:6px;z-index:99999;pointer-events:none;font:600 12px -apple-system;color:#000');
      document.body.appendChild(badge);
      var marks = [];
      for (var node = target.parentElement; node && node !== document.documentElement; node = node.parentElement) {
        node.setAttribute('data-lab-anc', '');
        var c = getComputedStyle(node), parts = [];
        if (c.overflowX !== 'visible' || c.overflowY !== 'visible') parts.push('o:' + c.overflowX + '/' + c.overflowY);
        if (c.transform !== 'none') parts.push('t:' + c.transform.slice(0, 22));
        if (c.filter !== 'none') parts.push('f');
        if (c.webkitBackdropFilter && c.webkitBackdropFilter !== 'none') parts.push('bf');
        if (c.willChange !== 'auto') parts.push('wc:' + c.willChange);
        if (c.clipPath !== 'none') parts.push('clip');
        if (c.webkitMaskImage && c.webkitMaskImage !== 'none') parts.push('mask');
        if (c.contain && c.contain !== 'none') parts.push('contain:' + c.contain);
        if (parseFloat(c.opacity) < 1) parts.push('op:' + c.opacity);
        if (parts.length) marks.push(node.tagName.toLowerCase() + '.' + String(node.className).split(' ').slice(0, 2).join('.') + ' ' + parts.join(' '));
      }
      var index = -1;
      function next() {
        index = (index + 1) % variants.length;
        style.textContent = variants[index][1];
        if (onStep) onStep(index);
        var r = target.getBoundingClientRect();
        badge.innerHTML = '<span style="background:#ff0;padding:3px 7px;border-radius:7px">' + variants[index][0] + '</span>' +
          '<div style="margin-top:4px;background:rgba(255,255,255,.85);padding:3px 6px;border-radius:6px;font:500 9px ui-monospace,monospace;white-space:pre-wrap">' +
          'rect ' + Math.round(r.top * 10) / 10 + '..' + Math.round(r.bottom * 10) / 10 + ' dpr ' + devicePixelRatio + '\\n' + marks.join('\\n') + '</div>';
      }
      next();
      setInterval(next, 3000);
    };
    """

    /// A signed-in session without a server: the send page and its options.
    private static let fakeSession = """
    (function () {
      var original = window.fetch.bind(window);
      var user = { id: '00000000-0000-4000-8000-000000000001', email: 'test@example.com', role: 'user', displayName: 'Test', username: 'test', discoverable: true, emailLookup: true, language: 'fr', storageUsed: 0, storageLimit: 10737418240, createdAt: '2026-01-01T00:00:00.000Z', verified: true, payments: false };
      function reply(status, body) {
        return Promise.resolve(new Response(JSON.stringify(body), { status: status, headers: { 'Content-Type': 'application/json' } }));
      }
      window.fetch = function (input, init) {
        var url = typeof input === 'string' ? input : input.url;
        if (url.indexOf('/api/health') >= 0) return original(input, init);
        if (url.indexOf('/api/auth/session') >= 0 || url.indexOf('/api/me') >= 0) return reply(200, { user: user });
        if (url.indexOf('/api/transfers') >= 0) return reply(200, { transfers: [] });
        if (url.indexOf('/api/chat/conversations') >= 0) return reply(200, { conversations: [] });
        if (url.indexOf('/api/') >= 0) return reply(404, { error: { code: 'not_found', message: 'test' } });
        return original(input, init);
      };
    })();
    """

    private static let switchVariants = labTools + """
    (function () {
      var variants = [
        ['W0 site', ''],
        ['W1 panneau sans clip', '[data-lab-anc].overflow-hidden{overflow:visible!important}'],
        ['W2 main sans clip', 'main{overflow:visible!important}'],
        ['W3 site, mot de passe actif', ''],
        ['W4 panneau sans clip, mot de passe actif', '[data-lab-anc].overflow-hidden{overflow:visible!important}']
      ];
      var timer = setInterval(function () {
        var open = Array.prototype.find.call(document.querySelectorAll('button[aria-expanded]'), function (b) { return /mot de passe|password/i.test(b.textContent); });
        if (!open) return;
        clearInterval(timer);
        if (open.getAttribute('aria-expanded') !== 'true') open.click();
        setTimeout(function () {
          var switches = document.querySelectorAll('button[role=switch]');
          if (!switches.length) return;
          switches[switches.length - 1].scrollIntoView({ block: 'center' });
          window.__lab(switches[switches.length - 1], variants, function (step) {
            var first = document.querySelectorAll('button[role=switch]')[0];
            var on = first.getAttribute('aria-checked') === 'true';
            if ((step >= 3) !== on) first.click();
            setTimeout(function () { var all = document.querySelectorAll('button[role=switch]'); all[all.length - 1].scrollIntoView({ block: 'center' }); }, 400);
          });
        }, 1500);
      }, 400);
    })();
    """
}
