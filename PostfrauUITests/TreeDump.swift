import XCTest

final class TreeDump: XCTestCase {
    func testWindowState() {
        let app = XCUIApplication()
        app.launchArguments = ["--local-root-name", "diag", "--reset-state"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 20)
        sleep(3)
        app.activate()
        sleep(2)

        let w = app.windows.firstMatch
        print("=====DIAG===== appState=\(app.state.rawValue) windows=\(app.windows.count) "
            + "exists=\(w.exists) hittable=\(w.isHittable) frame=\(w.exists ? "\(w.frame)" : "-")")
        let field = app.textFields["Request URL"]
        print("=====FIELD===== exists=\(field.exists) hittable=\(field.isHittable) "
            + "frame=\(field.exists ? "\(field.frame)" : "-")")
        let sidebar = app.staticTexts["Collection Postfrau Examples"]
        print("=====SIDEBAR===== exists=\(sidebar.exists) hittable=\(sidebar.isHittable)")
        let shot = XCUIScreen.main.screenshot().image
        if let tiff = shot.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
           let png = bmp.representation(using: .png, properties: [:]) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("postfrau-diag-screen.png")
            try? png.write(to: url)
            print("=====SCREEN===== \(url.path)")
        }
    }
}
