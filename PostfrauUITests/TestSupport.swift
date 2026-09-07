import XCTest

/// Brings the app to the front and waits until it can actually receive clicks.
///
/// XCUITest launches the app but does not guarantee it becomes frontmost — if another app holds
/// focus, every query still resolves against the accessibility tree while `click()` fails with
/// "unable to find hit point". Activating explicitly makes the tests independent of whatever else
/// is on screen.
@discardableResult
func activateAndWait(_ app: XCUIApplication, timeout: TimeInterval = 20) -> Bool {
    app.activate()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if app.windows.firstMatch.exists, app.windows.firstMatch.isHittable { return true }
        app.activate()
        Thread.sleep(forTimeInterval: 0.25)
    }
    return false
}
