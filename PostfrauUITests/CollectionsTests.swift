import XCTest

/// Phase 6's acceptance criteria.
final class CollectionsTests: XCTestCase {
    private var stateName: String!

    override func setUp() {
        continueAfterFailure = false
        stateName = "UITest-\(UUID().uuidString)"
    }

    private func launchApp(fresh: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--local-root-name", stateName] + (fresh ? ["--reset-state"] : [])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(activateAndWait(app), "the app window should be interactive")
        XCTAssertTrue(
            app.staticTexts["Collection Postfrau Examples"].waitForExistence(timeout: 15))
        return app
    }

    /// Scoped to the outline: a whole-app `descendants` query is slow, and times out outright
    /// once the sidebar holds thousands of rows.
    private func sidebarRow(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.outlines.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Clicks an item in the context menu that is currently open.
    ///
    /// Several of these names also exist in the menu bar ("New Request" in File, "Delete" in
    /// Edit), so the query has to pick the one that is actually on screen.
    private func clickContextMenuItem(_ app: XCUIApplication, _ title: String) {
        let matches = app.menuItems.matching(NSPredicate(format: "title == %@", title))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            for item in matches.allElementsBoundByIndex where item.isHittable {
                item.click()
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("no hittable “\(title)” menu item")
    }

    func testCreatesAThreeLevelTreeThatSurvivesARelaunch() {
        var app = launchApp()

        // A new collection, a folder inside it, and a request inside that.
        app.typeKey("n", modifierFlags: [.command, .shift])
        let collection = sidebarRow(app, "Collection New Collection")
        XCTAssertTrue(collection.waitForExistence(timeout: 10), "⌘⇧N should add a collection")

        collection.rightClick()
        clickContextMenuItem(app, "New Folder")
        let folder = sidebarRow(app, "Folder New Folder")
        XCTAssertTrue(folder.waitForExistence(timeout: 10))

        folder.rightClick()
        clickContextMenuItem(app, "New Request")
        XCTAssertTrue(
            sidebarRow(app, "GET New Request").waitForExistence(timeout: 10),
            "the request should appear inside the folder")

        // Give autosave its 300 ms, then quit properly so the flush runs.
        Thread.sleep(forTimeInterval: 1)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))

        app = launchApp(fresh: false)
        XCTAssertTrue(
            sidebarRow(app, "Collection New Collection").waitForExistence(timeout: 15),
            "the tree should persist")
        XCTAssertTrue(sidebarRow(app, "Folder New Folder").exists)
        XCTAssertTrue(sidebarRow(app, "GET New Request").exists)
    }

    /// Dragging still moves a request, now that pressing a row selects it.
    ///
    /// Selection moved onto the press (D54) so the highlight does not wait for the button to come
    /// up, and a gesture that fires on the press is exactly the kind of thing that can stop
    /// `draggable` ever starting. Synthetic `CGEvent` drags do not drive SwiftUI drag-and-drop at
    /// all — verified by a control run — so this is the only place the question can be settled.
    ///
    /// The assertion is structural rather than visual: the request is dragged out of the folder
    /// onto the collection root, then the folder is deleted. A request that never left would go
    /// with it.
    func testDraggingARequestOutOfAFolderStillMovesIt() {
        let app = launchApp()

        app.typeKey("n", modifierFlags: [.command, .shift])
        let collection = sidebarRow(app, "Collection New Collection")
        XCTAssertTrue(collection.waitForExistence(timeout: 10))

        collection.rightClick()
        clickContextMenuItem(app, "New Folder")
        let folder = sidebarRow(app, "Folder New Folder")
        XCTAssertTrue(folder.waitForExistence(timeout: 10))

        folder.rightClick()
        clickContextMenuItem(app, "New Request")
        let request = sidebarRow(app, "GET New Request")
        XCTAssertTrue(request.waitForExistence(timeout: 10))

        request.press(forDuration: 0.3, thenDragTo: collection)
        Thread.sleep(forTimeInterval: 1)

        folder.rightClick()
        clickContextMenuItem(app, "Delete")
        XCTAssertFalse(
            sidebarRow(app, "Folder New Folder").waitForExistence(timeout: 5),
            "the folder should be gone")
        XCTAssertTrue(
            sidebarRow(app, "GET New Request").exists,
            "the request should have been dragged out of the folder, so deleting the folder "
                + "should not take it too")
    }

    func testDeletingARequestCanBeUndone() {
        let app = launchApp()

        let request = sidebarRow(app, "GET Echo query")
        XCTAssertTrue(request.waitForExistence(timeout: 10))

        request.rightClick()
        clickContextMenuItem(app, "Delete")
        XCTAssertFalse(
            sidebarRow(app, "GET Echo query").waitForExistence(timeout: 3),
            "the request should be gone")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(
            sidebarRow(app, "GET Echo query").waitForExistence(timeout: 10),
            "⌘Z should bring it back")
    }

    func testDuplicatingARequestAddsACopy() {
        let app = launchApp()

        let request = sidebarRow(app, "GET Echo query")
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        request.rightClick()
        clickContextMenuItem(app, "Duplicate")

        XCTAssertTrue(
            sidebarRow(app, "GET Echo query copy").waitForExistence(timeout: 10),
            "the copy should be listed next to the original")
        XCTAssertTrue(sidebarRow(app, "GET Echo query").exists, "the original should still be there")
    }

    func testFilteringKeepsAncestorsVisible() {
        let app = launchApp()

        let filter = app.searchFields.firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        filter.click()
        filter.typeText("POST JSON")

        // "POST JSON" lives inside the "Bodies" folder; filtering must open the way to it.
        XCTAssertTrue(
            sidebarRow(app, "POST POST JSON").waitForExistence(timeout: 10),
            "the match should be visible")
        XCTAssertTrue(sidebarRow(app, "Folder Bodies").exists, "its folder should be kept")
        XCTAssertFalse(sidebarRow(app, "GET Echo query").exists, "non-matches should be hidden")
    }

    func testQuickOpenFindsARequestByFuzzyMatch() {
        let app = launchApp()

        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["Quick open search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "⌘K should open the panel")
        search.typeText("stcook")   // "Set a cookie", fuzzily

        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH 'GET Set a cookie'")).firstMatch
                .waitForExistence(timeout: 10),
            "fuzzy matching should find the request")

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Set a cookie'"))
                .firstMatch.waitForExistence(timeout: 10),
            "pressing return should open it in a tab")
    }

    func testEditingACollectionsVariablesFromItsEditorTab() {
        let app = launchApp()

        sidebarRow(app, "Collection Postfrau Examples").doubleClick()
        XCTAssertTrue(
            app.textFields["Collection name"].waitForExistence(timeout: 10),
            "double-clicking a collection should open its editor")

        app.radioButtons["Variables"].click()
        let names = app.textFields.matching(identifier: "Variable name")
        XCTAssertTrue(names.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(names.element(boundBy: 0).value as? String, "baseUrl")
    }
}

extension CollectionsTests {
    /// `PLAN.md` §1: the app has to stay usable with a 5 000-request collection.
    ///
    /// Typing through XCUITest is slow in its own right, so the test times the *same* typing twice
    /// — once against the 7-request sample and once with 5 000 more loaded — and compares. That
    /// isolates the app's cost from the harness's.
    func testFiveThousandRequestsScrollAndFilterWithoutLag() {
        let app = launchApp()

        let filter = app.searchFields.firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 10))

        // Control: the sample collection alone.
        let baseline = timeFiltering(app, filter: filter, query: "cookie")

        // Clear the control's query first: a still-active filter would correctly hide the
        // collection we are about to generate.
        clearFilter(app, filter)

        // Now add 5 000 requests.
        app.menuBarItems["Debug"].click()
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Generate Stress'"))
            .firstMatch.click()
        XCTAssertTrue(
            sidebarRow(app, "Collection Stress Test").waitForExistence(timeout: 120),
            "the generated collection should appear")

        let counts = app.staticTexts.matching(identifier: "workspaceCounts").firstMatch
        XCTAssertTrue(counts.waitForExistence(timeout: 30))
        let summary = (counts.value as? String) ?? counts.label
        XCTAssertTrue(
            summary.contains("5007 requests"),
            "expected 5 000 generated plus the 7 samples, got “\(summary)”")

        // The same typing, now against 5 007 requests.
        let loaded = timeFiltering(app, filter: filter, query: "item4999")
        let match = app.outlines.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH 'Request 4999'")).firstMatch
        XCTAssertTrue(
            match.waitForExistence(timeout: 60),
            "filtering 5 000 requests should find the match")

        // Both queries are eight characters, so the difference is the app's, not the harness's.
        XCTAssertLessThan(
            loaded, baseline * 4 + 5,
            "filtering 5 007 requests took \(loaded)s against \(baseline)s for 7 — "
                + "the sidebar does not scale")

        // Clearing the filter puts the whole tree back, and the outline still scrolls.
        clearFilter(app, filter)
        XCTAssertTrue(
            sidebarRow(app, "Collection Stress Test").waitForExistence(timeout: 30))
        app.outlines.firstMatch.scroll(byDeltaX: 0, deltaY: -600)
        XCTAssertTrue(app.outlines.firstMatch.exists)
    }

    /// Types `query` into the filter and returns how long it took for the field to hold it.
    private func timeFiltering(
        _ app: XCUIApplication, filter: XCUIElement, query: String
    ) -> TimeInterval {
        clearFilter(app, filter)
        filter.click()
        // The click has to land before typing, or the event goes nowhere.
        let focusDeadline = Date().addingTimeInterval(10)
        while Date() < focusDeadline, !filter.hasFocus { Thread.sleep(forTimeInterval: 0.1) }

        let started = Date()
        app.typeText(query)
        // Wait for the field itself to settle, not for any particular row.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, (filter.value as? String) != query {
            Thread.sleep(forTimeInterval: 0.1)
        }
        return Date().timeIntervalSince(started)
    }

    private func clearFilter(_ app: XCUIApplication, _ filter: XCUIElement) {
        // Nothing to clear, and typing into an unfocused field throws.
        guard let current = filter.value as? String, !current.isEmpty else { return }
        let clear = filter.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'clear'")).firstMatch
        if clear.exists {
            clear.click()
        } else {
            filter.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
        }
    }
}

extension XCUIElement {
    /// Whether this element (or something inside it) currently has keyboard focus.
    var hasFocus: Bool {
        (value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }
}
