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
        XCTAssertTrue(code.waitForExistence(timeout: 20), "code field")
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
}
