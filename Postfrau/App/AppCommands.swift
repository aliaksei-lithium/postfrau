import SwiftUI
import PostfrauCore

/// One menu item.
///
/// The enabled test runs inside *this* view's body rather than in the `App`'s `commands` builder.
/// Reading `@Observable` state directly in the commands builder makes the whole Scene — window
/// included — a dependency of that state, so every edit tears the window down and rebuilds it, and
/// the app ends up with no visible window at all.
private struct CommandButton: View {
    var title: String
    var state: AppState?
    var isEnabled: (AppState) -> Bool = { _ in true }
    var action: (AppState) -> Void

    var body: some View {
        Button(title) {
            guard let state else { return }
            action(state)
        }
        .disabled(state.map { !isEnabled($0) } ?? true)
    }
}

/// The menu bar. Every shortcut in `PLAN.md` §5 lives here so it is discoverable, and so the
/// keyboard works even when focus is inside a text field.
///
/// The state is handed in directly rather than picked up with `@FocusedValue`: Postfrau is a
/// single-window app, so there is only ever one `AppState`, and routing through focus left
/// commands silently disabled whenever the focused value had not propagated — a menu item that
/// looks enabled, accepts a click, and does nothing.
struct AppCommands: Commands {
    var state: AppState?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            CommandButton(title: "New Request", state: state) { $0.newTab() }
                .keyboardShortcut("n", modifiers: .command)
            CommandButton(title: "New Tab", state: state) { $0.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            CommandButton(title: "New Collection", state: state) { $0.newCollection() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Divider()
            CommandButton(title: "Import…", state: state) { $0.runImportPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])

            CommandButton(
                title: "Export Collection…", state: state,
                isEnabled: { $0.exportableCollectionID != nil },
                action: { state in
                    if let id = state.exportableCollectionID { state.exportCollection(id) }
                })

            CommandButton(
                title: "Export Environment…", state: state,
                isEnabled: { $0.workspace.activeEnvironment != nil },
                action: { state in
                    if let id = state.workspace.activeEnvironmentID {
                        state.exportEnvironment(id)
                    }
                })
        }

        CommandGroup(after: .saveItem) {
            CommandButton(
                title: "Save Request", state: state,
                isEnabled: { $0.selectedTab?.kind == .request },
                action: { state in
                    guard let tab = state.selectedTab else { return }
                    state.saveTab(tab)
                })
            .keyboardShortcut("s", modifiers: .command)
        }

        CommandGroup(replacing: .textEditing) {}

        CommandMenu("Request") {
            CommandButton(
                title: "Send", state: state,
                isEnabled: { $0.selectedTab?.kind == .request },
                action: { state in
                    guard let tab = state.selectedTab else { return }
                    state.send(tab)
                })
            .keyboardShortcut(.return, modifiers: .command)

            CommandButton(
                title: "Cancel", state: state,
                isEnabled: { $0.selectedTab?.isSending == true },
                action: { state in
                    guard let tab = state.selectedTab else { return }
                    state.cancelSend(tab)
                })
            .keyboardShortcut(".", modifiers: .command)

            Divider()

            CommandButton(
                title: "Copy as cURL", state: state,
                isEnabled: { $0.selectedTab?.kind == .request },
                action: { state in
                    guard let tab = state.selectedTab else { return }
                    state.copyAsCurl(tab)
                })
            .keyboardShortcut("c", modifiers: [.command, .shift])

            CommandButton(
                title: "Copy as cURL Keeping Variables", state: state,
                isEnabled: { $0.selectedTab?.kind == .request },
                action: { state in
                    guard let tab = state.selectedTab else { return }
                    state.copyAsCurl(tab, handling: .raw)
                })

            Divider()

            CommandButton(title: "Quick Open…", state: state) { $0.isQuickOpenPresented = true }
                .keyboardShortcut("k", modifiers: .command)

            CommandButton(title: "Focus URL", state: state) { $0.focusURLField() }
                .keyboardShortcut("l", modifiers: .command)

            CommandButton(
                title: "Find in Response", state: state,
                isEnabled: { $0.selectedTab?.response != nil },
                action: { $0.selectedTab?.findRequests += 1 })
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            ForEach(Array(EditorTab.allCases.enumerated()), id: \.element) { index, editorTab in
                CommandButton(
                    title: editorTab.title, state: state,
                    isEnabled: { $0.selectedTab?.kind == .request },
                    action: { $0.selectedTab?.selectedEditorTab = editorTab })
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }

        CommandMenu("History") {
            CommandButton(
                title: "Open Last Send", state: state,
                isEnabled: { !$0.historyEntries.isEmpty },
                action: { state in
                    if let entry = state.historyEntries.first { state.openHistoryEntry(entry) }
                })
            .keyboardShortcut("h", modifiers: [.command, .shift])

            CommandButton(
                title: "Show History", state: state,
                action: { $0.sidebarSection = .history })

            Divider()

            CommandButton(
                title: "Delete All History…", state: state,
                isEnabled: { !$0.historyEntries.isEmpty },
                action: { $0.isConfirmingClearHistory = true })
        }

        CommandGroup(after: .windowList) {
            CommandButton(title: "Next Tab", state: state) { $0.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            CommandButton(title: "Previous Tab", state: state) { $0.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            // The ⌘W here is the menu's label; `AppDelegate` intercepts the keystroke itself,
            // because AppKit's File ▸ Close would otherwise win the key equivalent.
            CommandButton(title: "Close Tab", state: state) { $0.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            CommandButton(title: "Toggle Response Layout", state: state) {
                $0.toggleResponseLayout()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
        }

        #if DEBUG
        CommandMenu("Debug") {
            // §1 asks the app to stay usable with 5 000 requests; this is how that gets measured.
            CommandButton(title: "Generate Stress Collection (5 000)", state: state) {
                $0.generateStressCollection()
            }
        }
        #endif
    }
}

/// The identifier of the environments window, shared by the scene and the menu command.
enum EnvironmentsWindowID {
    static let value = "environments"
}
