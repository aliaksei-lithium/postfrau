import XCTest

/// End-to-end checks driven through the real UI: the acceptance criteria for the phases that add
/// UI, run automatically rather than by eye.
///
/// Each test gets a fresh machine-local state directory via `POSTFRAU_LOCAL_ROOT`, so tabs and
/// history from one test never leak into the next. The directory lives inside the app's sandbox
/// container, which is the only place a sandboxed process may write.
final class LaunchTests: XCTestCase {
    /// A name, not a path: this runner is itself sandboxed into
    /// `com.postfrau.PostfrauUITests.xctrunner`, so any directory it can create is one the app is
    /// forbidden to write. The app places the folder inside its own container instead.
    private var stateName: String!

    override func setUp() {
        continueAfterFailure = false
        stateName = "UITest-\(UUID().uuidString)"
    }

    /// - Parameter fresh: wipe the state folder first. Pass false on a relaunch that is meant to
    ///   restore the previous session.
    @discardableResult
    private func launchApp(fresh: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        // Launch *arguments* rather than `launchEnvironment`: the latter does not reach an app
        // launched through LaunchServices.
        app.launchArguments = ["--local-root-name", stateName] + (fresh ? ["--reset-state"] : [])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        return app
    }

    func testAppLaunchesWithTheSampleCollection() {
        let app = launchApp()
        XCTAssertTrue(
            app.staticTexts["Collection Postfrau Examples"].waitForExistence(timeout: 15),
            "the sample collection should be in the sidebar on first run")
        XCTAssertTrue(app.staticTexts["No response yet"].exists)
        XCTAssertTrue(app.textFields["Request URL"].exists)
    }

    func testSendingARequestShowsAStatusBodyAndHeaders() {
        let app = launchApp()

        let urlField = app.textFields["Request URL"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 15))
        urlField.click()
        urlField.typeText("https://example.com")

        app.buttons["Send the request"].click()

        // The status pill is one combined element so VoiceOver reads it as a sentence.
        let status = app.staticTexts["Status 200 OK"]
        XCTAssertTrue(status.waitForExistence(timeout: 30), "expected a 200 response")

        let body = app.textViews["Response body"]
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        XCTAssertTrue(
            (body.value as? String ?? "").contains("<html"),
            "expected the HTML body in the response view")

        // The request editor has a "Headers" tab too; the response one carries a count, so the
        // trailing "(" disambiguates without depending on the picker's container.
        app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH 'Headers ('"))
            .firstMatch.click()
        XCTAssertTrue(app.staticTexts["Content-Type"].waitForExistence(timeout: 10))
    }

    func testOpeningASampleRequestFromTheSidebarAndSendingIt() {
        let app = launchApp()

        // The sample collection is expanded on first run, so its top-level requests are visible.
        let collection = app.staticTexts["Collection Postfrau Examples"]
        XCTAssertTrue(collection.waitForExistence(timeout: 15))

        // The row carries the `.isButton` trait, so it is a button rather than static text.
        let request = app.buttons["GET Echo query"]
        XCTAssertTrue(request.waitForExistence(timeout: 10), "the sample request should be listed")
        request.doubleClick()

        // Double-clicking replaces the untouched scratch tab and fills in the saved request.
        let urlField = app.textFields["Request URL"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 10))
        XCTAssertEqual(urlField.value as? String, "{{baseUrl}}/get")

        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts["Status 200 OK"].waitForExistence(timeout: 30),
            "sending the sample request should return 200")
    }

    func testCancellingASlowRequestStopsIt() {
        let app = launchApp()

        let urlField = app.textFields["Request URL"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 15))
        urlField.click()
        urlField.typeText("https://httpbin.org/delay/10")

        app.buttons["Send the request"].click()

        let cancel = app.buttons["Cancel the request"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Send should become Cancel in flight")
        cancel.click()

        XCTAssertTrue(
            app.buttons["Send the request"].waitForExistence(timeout: 10),
            "cancelling should restore the Send button well before the 10 s delay elapses")
        XCTAssertFalse(app.staticTexts["Status 200 OK"].exists)
    }

    func testTabsAreRestoredAfterRelaunch() {
        var app = launchApp()

        let urlField = app.textFields["Request URL"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 15))
        urlField.click()
        urlField.typeText("https://restored.example")
        // Opening a second tab makes the restored state unambiguous.
        app.typeKey("t", modifierFlags: .command)
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label CONTAINS 'New Request'")).count, 1,
            "⌘T should open a second tab")

        // ⌘Q rather than `terminate()`: XCUITest's terminate kills the process outright, which
        // skips `applicationShouldTerminate` and therefore the flush that persists the last edit.
        // Quitting the way a user does is also the behaviour worth testing.
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))

        app = launchApp(fresh: false)
        // A tab's label carries its dirty state, so match on the prefix.
        let restored = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "restored.example")).firstMatch
        XCTAssertTrue(
            restored.waitForExistence(timeout: 20),
            "the previous session's tabs should come back")
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label CONTAINS 'New Request'")).count, 1,
            "the second, empty tab should come back too")
    }
}
