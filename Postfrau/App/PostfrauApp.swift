import SwiftUI

@main
struct PostfrauApp: App {
    var body: some Scene {
        Window("Postfrau", id: "main") {
            MainWindow()
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
    }
}
