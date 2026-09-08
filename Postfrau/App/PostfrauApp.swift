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
                // `postfrau open <path>` sends `postfrau://open?id=<uuid>`. This rather than
                // `application(_:open:)` on the delegate: SwiftUI installs its own Apple Event
                // handler for URLs, so the delegate method is never called in a SwiftUI app.
                .onOpenURL { url in
                    appDelegate.bringMainWindowForward()
                    state.handleIncoming(url)
                }
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(state: state) }

        // A separate window rather than a sheet: environments are edited *while* looking at a
        // request, and a sheet would hide the very thing whose variables you are fixing.
        Window("Environments", id: EnvironmentsWindowID.value) {
            EnvironmentsWindow()
                .environment(state)
        }
        .defaultSize(width: 820, height: 480)
        .keyboardShortcut("e", modifiers: .command)

        Settings {
            SettingsWindow()
                .environment(state)
        }
        .onChange(of: scenePhase) { _, phase in
            // Flush on background so a force-quit cannot lose the last 300 ms of edits.
            if phase != .active {
                Task { await state.flush() }
            }
        }
    }
}
