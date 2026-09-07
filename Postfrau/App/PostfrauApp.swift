import SwiftUI
import PostfrauCore

@main
struct PostfrauApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.makeDefault()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Postfrau", id: "main") {
            MainWindow()
                .environment(state)
                .task {
                    appDelegate.state = state
                    await state.load()
                }
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands { AppCommands() }
        .onChange(of: scenePhase) { _, phase in
            // Flush on background so a force-quit cannot lose the last 300 ms of edits.
            if phase != .active {
                Task { await state.flush() }
            }
        }
    }
}
