import XCTest

/// Drives the app into interesting states and saves PNGs, so the UI can be reviewed without a
/// human at the keyboard — and so README screenshots are reproducible.
///
/// Run with: `xcodebuild test -only-testing:PostfrauUITests/ScreenshotTests`.
/// The files land in the test runner's container; the path is printed for each one.
final class ScreenshotTests: XCTestCase {
    private var stateName: String!

    override func setUp() {
        continueAfterFailure = false
        stateName = "Screenshots"
    }

    func testCaptureMainWindow() {
        capture(appearance: nil, prefix: "light")
    }

    func testCaptureMainWindowInDarkMode() {
        // `-AppleInterfaceStyle Dark` goes into this process's argument domain, so AppKit renders
        // it dark without touching the machine's system-wide setting.
        capture(appearance: "dark", prefix: "dark")
    }

    private func capture(appearance: String?, prefix: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--local-root-name", stateName + (appearance ?? ""), "--reset-state"]
            + (appearance.map { ["--appearance", $0] } ?? [])
        self.prefix = prefix
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(activateAndWait(app), "the app window should be interactive")
        XCTAssertTrue(
            app.staticTexts["Collection Postfrau Examples"].waitForExistence(timeout: 15))

        save(app, named: "01-empty")

        // Open a sample request and send it so the response pane has something in it.
        let request = app.buttons["GET Echo query"]
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        request.doubleClick()
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Status 200 OK"].waitForExistence(timeout: 30))
        sleep(1)
        save(app, named: "02-response")

        // The response's headers table.
        app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH 'Headers ('"))
            .firstMatch.click()
        sleep(1)
        save(app, named: "03-headers")
    }

    private var prefix = "light"

    private func save(_ app: XCUIApplication, named name: String) {
        let image = app.windows.firstMatch.screenshot().image
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return XCTFail("could not encode \(name)") }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("postfrau-\(prefix)-\(name).png")
        do {
            try png.write(to: url)
            print("=====SHOT===== \(url.path)")
        } catch {
            XCTFail("could not write \(name): \(error)")
        }
    }
}
