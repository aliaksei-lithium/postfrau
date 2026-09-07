import XCTest

/// Phase 5's acceptance criteria.
///
/// The large-response test needs a local server holding a ~20 MB JSON file. Start one with:
///
///     (cd <fixtures> && python3 -m http.server 8792)
///
/// When it is not running the test records a known issue and returns, so `make test` stays green
/// on a machine that has not set the fixture up.
final class ResponseViewerTests: XCTestCase {
    private var stateName: String!

    /// Where the big fixture is served from.
    private static let largeBodyURL = "http://127.0.0.1:8792/big.json"

    override func setUp() {
        continueAfterFailure = false
        stateName = "UITest-\(UUID().uuidString)"
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--local-root-name", stateName, "--reset-state"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(app.textFields["Request URL"].waitForExistence(timeout: 15))
        return app
    }

    private func send(_ app: XCUIApplication, to url: String) {
        let field = app.textFields["Request URL"]
        field.click()
        field.typeText(url)
        app.buttons["Send the request"].click()
    }

    func testPrettyPrintsAndHighlightsAJSONResponse() {
        let app = launchApp()
        send(app, to: "https://httpbin.org/get?alpha=1")

        XCTAssertTrue(app.staticTexts["Status 200 OK"].waitForExistence(timeout: 30))

        let body = app.textViews["Response body"]
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        let pretty = body.value as? String ?? ""
        // httpbin already returns indented JSON, so assert on Postfrau's own shape: two-space
        // indent and a space after the colon.
        XCTAssertTrue(pretty.contains("\n  \"args\": {"), "not pretty-printed: \(pretty.prefix(200))")

        // Raw shows the same bytes without re-indenting.
        app.radioButtons["Raw"].click()
        let raw = body.value as? String ?? ""
        XCTAssertTrue(raw.contains("\"args\""))
    }

    func testPreviewRendersHTML() {
        let app = launchApp()
        send(app, to: "https://example.com")

        XCTAssertTrue(app.staticTexts["Status 200 OK"].waitForExistence(timeout: 30))
        app.radioButtons["Preview"].click()

        // The WebView renders the page's text.
        XCTAssertTrue(
            app.webViews.firstMatch.waitForExistence(timeout: 20),
            "the preview should render the HTML in a web view")
        // The rendered page's own text comes through the web view's accessibility tree.
        XCTAssertTrue(
            app.webViews.firstMatch.staticTexts["Example Domain"].waitForExistence(timeout: 20),
            "the page content should be rendered")
    }

    func testTimingPopoverShowsTheBreakdown() {
        let app = launchApp()
        send(app, to: "https://example.com")

        XCTAssertTrue(app.staticTexts["Status 200 OK"].waitForExistence(timeout: 30))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Took'")).firstMatch.click()

        XCTAssertTrue(
            app.staticTexts["Timing"].waitForExistence(timeout: 10),
            "clicking the duration should open the timing popover")
    }

    func testALargeResponseStaysResponsive() throws {
        // XCTest has no skip-without-failing, so this is an explicit throw the runner reports
        // as "skipped" rather than a failure.
        try XCTSkipUnless(
            Self.isFixtureServerRunning(),
            "no fixture server on 127.0.0.1:8792 — see this file's doc comment")

        let app = launchApp()
        send(app, to: Self.largeBodyURL)

        XCTAssertTrue(
            app.staticTexts["Status 200 OK"].waitForExistence(timeout: 60),
            "the large body should download")

        // Above the render limit the viewer shows a slice, not the whole thing. The banner is a
        // combined accessibility element, so match on any descendant's label.
        let banner = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Showing the first'")).firstMatch
        XCTAssertTrue(
            banner.waitForExistence(timeout: 30),
            "a 20 MB body should be truncated for display")

        let body = app.textViews["Response body"]
        XCTAssertTrue(body.waitForExistence(timeout: 30))

        // Switching views must stay interactive — each of these times out if the UI is wedged.
        let started = Date()
        app.radioButtons["Raw"].click()
        XCTAssertTrue(body.waitForExistence(timeout: 20))
        app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH 'Headers ('"))
            .firstMatch.click()
        XCTAssertTrue(app.staticTexts["Content-Type"].waitForExistence(timeout: 20))
        app.radioButtons["Pretty"].click()
        XCTAssertTrue(body.waitForExistence(timeout: 20))

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 20, "switching views on a large response took \(elapsed)s")

        // Scrolling does not beachball.
        body.scroll(byDeltaX: 0, deltaY: -400)
        XCTAssertTrue(app.staticTexts["Status 200 OK"].exists)
    }

    /// A short synchronous probe; the fixture server is optional.
    private static func isFixtureServerRunning() -> Bool {
        var request = URLRequest(url: URL(string: largeBodyURL)!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 2
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reachable = false
        URLSession(configuration: .ephemeral).dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        return reachable
    }
}
