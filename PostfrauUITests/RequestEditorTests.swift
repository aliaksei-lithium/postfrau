import XCTest

/// Phase 4's acceptance criteria, driven through the UI.
final class RequestEditorTests: XCTestCase {
    private var stateName: String!

    override func setUp() {
        continueAfterFailure = false
        stateName = "UITest-\(UUID().uuidString)"
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--local-root-name", stateName, "--reset-state"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(app.textFields["Request URL"].waitForExistence(timeout: 15)
            || app.textViews["Request URL"].waitForExistence(timeout: 5))
        return app
    }

    /// The URL field is an `NSTextView`, so it comes through as a text view rather than a field.
    private func urlField(_ app: XCUIApplication) -> XCUIElement {
        let textView = app.textViews["Request URL"]
        return textView.exists ? textView : app.textFields["Request URL"]
    }

    private func selectEditorTab(_ app: XCUIApplication, labelPrefix: String) {
        app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix))
            .firstMatch.click()
    }

    func testPostsJSONWithBearerAuthAndParamsAndTheServerEchoesEverything() {
        let app = launchApp()

        // Method.
        app.popUpButtons.matching(NSPredicate(format: "label CONTAINS 'HTTP method'"))
            .firstMatch.click()
        app.menuItems["POST"].click()

        // URL.
        let url = urlField(app)
        url.click()
        url.typeText("https://httpbin.org/anything")

        // Two query parameters, typed into the Params table.
        selectEditorTab(app, labelPrefix: "Params")
        let keyFields = app.textFields.matching(identifier: "Parameter name")
        XCTAssertTrue(keyFields.firstMatch.waitForExistence(timeout: 10))
        typeRow(app, key: "alpha", value: "one", rowIndex: 0)
        typeRow(app, key: "beta", value: "two", rowIndex: 1)

        // The URL must have picked the parameters up.
        XCTAssertTrue(
            (url.value as? String ?? "").contains("alpha=one"),
            "editing params should rewrite the URL, got \(url.value ?? "nil")")

        // Bearer token.
        selectEditorTab(app, labelPrefix: "Auth")
        app.popUpButtons.matching(NSPredicate(format: "label CONTAINS 'Authentication type'"))
            .firstMatch.click()
        app.menuItems["Bearer Token"].click()
        let token = app.secureTextFields["Token"]
        XCTAssertTrue(token.waitForExistence(timeout: 10))
        token.click()
        token.typeText("s3cret-token")

        // JSON body.
        selectEditorTab(app, labelPrefix: "Body")
        app.radioButtons["Raw"].click()
        let body = app.textViews["Request body"]
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        body.click()
        body.typeText("{\"hello\":\"world\"}")

        app.buttons["Send the request"].click()
        XCTAssertTrue(
            app.staticTexts["Status 200 OK"].waitForExistence(timeout: 30),
            "expected httpbin to answer")

        // httpbin echoes the whole request back, so one body check covers all of it.
        let responseBody = app.textViews["Response body"]
        XCTAssertTrue(responseBody.waitForExistence(timeout: 15))
        let text = responseBody.value as? String ?? ""
        XCTAssertTrue(text.contains("\"alpha\": \"one\""), "query params were not sent: \(text)")
        XCTAssertTrue(text.contains("\"beta\": \"two\""), "query params were not sent")
        XCTAssertTrue(text.contains("Bearer s3cret-token"), "bearer token was not sent")
        XCTAssertTrue(text.contains("\"hello\": \"world\""), "JSON body was not sent")
        XCTAssertTrue(text.contains("application/json"), "Content-Type was not set")
    }

    func testEditingTheURLPopulatesTheParamsTable() {
        let app = launchApp()

        let url = urlField(app)
        url.click()
        url.typeText("https://httpbin.org/get?limit=25&q=hello")

        selectEditorTab(app, labelPrefix: "Params")

        let keyFields = app.textFields.matching(identifier: "Parameter name")
        XCTAssertTrue(keyFields.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(keyFields.element(boundBy: 0).value as? String, "limit")
        XCTAssertEqual(keyFields.element(boundBy: 1).value as? String, "q")

        let valueFields = app.textFields.matching(identifier: "Parameter value")
        XCTAssertEqual(valueFields.element(boundBy: 0).value as? String, "25")
        XCTAssertEqual(valueFields.element(boundBy: 1).value as? String, "hello")

        // Params always offer one blank row to type into.
        XCTAssertEqual(keyFields.count, 3)
    }

    func testDisablingAParameterRemovesItFromTheURL() {
        let app = launchApp()

        let url = urlField(app)
        url.click()
        url.typeText("https://httpbin.org/get?keep=1&drop=2")

        selectEditorTab(app, labelPrefix: "Params")
        let checkboxes = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH 'Enable'"))
        XCTAssertTrue(checkboxes.firstMatch.waitForExistence(timeout: 10))
        app.checkBoxes["Enable drop"].click()

        let text = url.value as? String ?? ""
        XCTAssertTrue(text.contains("keep=1"), "enabled param should stay: \(text)")
        XCTAssertFalse(text.contains("drop=2"), "disabled param should go: \(text)")
    }

    func testBeautifyReindentsAJSONBodyWithoutChangingIt() {
        let app = launchApp()

        selectEditorTab(app, labelPrefix: "Body")
        app.radioButtons["Raw"].click()
        let body = app.textViews["Request body"]
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        body.click()
        body.typeText("{\"b\":9007199254740993,\"a\":[1,2]}")

        app.buttons["Beautify the JSON body"].click()

        let text = body.value as? String ?? ""
        XCTAssertTrue(text.contains("\n"), "the body should be re-indented: \(text)")
        // Key order and full integer precision survive.
        XCTAssertTrue(text.contains("\"b\": 9007199254740993"), text)
        XCTAssertLessThan(
            text.range(of: "\"b\"")!.lowerBound, text.range(of: "\"a\"")!.lowerBound,
            "key order must be preserved")
    }

    func testTheHeadersTabShowsWhatPostfrauWillAdd() {
        let app = launchApp()

        let url = urlField(app)
        url.click()
        url.typeText("https://httpbin.org/get")

        selectEditorTab(app, labelPrefix: "Headers")
        // Combined rows come through as generic elements, not static text.
        XCTAssertTrue(
            app.otherElements.matching(
                NSPredicate(format: "label BEGINSWITH 'Automatic header User-Agent'"))
                .firstMatch.waitForExistence(timeout: 10),
            "the auto-headers section should list User-Agent")
    }

    func testClosingATabWithUnsavedChangesAsksFirst() {
        let app = launchApp()

        // Open a saved request, then edit it.
        let request = app.buttons["GET Echo query"]
        XCTAssertTrue(request.waitForExistence(timeout: 15))
        request.doubleClick()

        let url = urlField(app)
        url.click()
        url.typeText("/edited")

        app.typeKey("w", modifierFlags: .command)

        // "Don't Save" is unique to this dialog, so it is the reliable thing to wait on.
        // Scoped to the window: macOS also mirrors dialog buttons into the Touch Bar, and those
        // copies cannot be clicked.
        XCTAssertTrue(
            app.windows.firstMatch.buttons["Don't Save"].waitForExistence(timeout: 10),
            "closing a dirty tab should ask first")
        // Escape is the standard way to take the cancel button.
        app.typeKey(.escape, modifierFlags: [])


        // The tab survives, because the close was cancelled.
        let tab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Echo query'"))
            .firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        XCTAssertTrue(
            (tab.label).contains("unsaved changes"),
            "the tab should still be marked dirty, got “\(tab.label)”")

        // Closing again and choosing "Don't Save" really does close it.
        app.typeKey("w", modifierFlags: .command)
        let discard = app.windows.firstMatch.buttons["Don't Save"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        discard.click()
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Echo query'"))
                .firstMatch.waitForExistence(timeout: 5),
            "the tab should be gone")
    }

    func testFormDataWithAFileUploadEchoesTheFileName() throws {
        // A file the app is allowed to read: the sandbox grants its own container.
        let attachment = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("postfrau-upload-\(UUID().uuidString).txt")
        try "hello from postfrau".write(to: attachment, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: attachment) }

        let app = launchApp()

        app.popUpButtons.matching(NSPredicate(format: "label CONTAINS 'HTTP method'"))
            .firstMatch.click()
        app.menuItems["POST"].click()

        let url = urlField(app)
        url.click()
        url.typeText("https://httpbin.org/post")

        selectEditorTab(app, labelPrefix: "Body")
        app.radioButtons["Form Data"].click()

        let fieldName = app.textFields["Field name"]
        XCTAssertTrue(fieldName.waitForExistence(timeout: 10))
        fieldName.click()
        fieldName.typeText("attachment")

        // Switch the row to a file and pick one through the open panel.
        app.popUpButtons.matching(NSPredicate(format: "label CONTAINS 'Field type'"))
            .firstMatch.click()
        app.menuItems["File"].click()

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Choose a file'"))
            .firstMatch.click()

        // Drive the open panel by path: typing "/" opens its "Go to the folder" sheet.
        let attachButton = app.buttons["Attach"]
        XCTAssertTrue(attachButton.waitForExistence(timeout: 20), "the open panel should appear")
        app.typeText(attachment.path)
        app.typeKey(.return, modifierFlags: [])   // confirm "Go to the folder"
        Thread.sleep(forTimeInterval: 1)
        app.typeKey(.return, modifierFlags: [])   // confirm the panel
        XCTAssertFalse(
            attachButton.waitForExistence(timeout: 5), "the panel should have closed")

        // The row now shows the attached file.
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "File \(attachment.lastPathComponent)"))
                .firstMatch.waitForExistence(timeout: 10),
            "the row should show the attached file")

        app.buttons["Send the request"].click()
        XCTAssertTrue(
            app.staticTexts["Status 200 OK"].waitForExistence(timeout: 30),
            "expected httpbin to answer")

        let responseBody = app.textViews["Response body"]
        XCTAssertTrue(responseBody.waitForExistence(timeout: 15))
        let text = responseBody.value as? String ?? ""
        XCTAssertTrue(text.contains("hello from postfrau"), "file contents were not sent: \(text)")
        XCTAssertTrue(text.contains("attachment"), "the field name was not sent")
    }

    // MARK: - Helpers

    /// Fills the key and value of one key/value row.
    private func typeRow(_ app: XCUIApplication, key: String, value: String, rowIndex: Int) {
        let keyField = app.textFields.matching(identifier: "Parameter name")
            .element(boundBy: rowIndex)
        keyField.click()
        keyField.typeText(key)
        let valueField = app.textFields.matching(identifier: "Parameter value")
            .element(boundBy: rowIndex)
        valueField.click()
        valueField.typeText(value)
    }
}
