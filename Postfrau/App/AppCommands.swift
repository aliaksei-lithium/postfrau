import SwiftUI
import PostfrauCore

/// Lets menu commands reach the window's `AppState`.
struct AppStateFocusKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var appState: AppState? {
        get { self[AppStateFocusKey.self] }
        set { self[AppStateFocusKey.self] = newValue }
    }
}

/// The menu bar. Every shortcut in `PLAN.md` §5 lives here so it is discoverable, and so the
/// keyboard works even when focus is inside a text field.
struct AppCommands: Commands {
    @FocusedValue(\.appState) private var state

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Request") { state?.newTab() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(state == nil)
            Button("New Tab") { state?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(state == nil)
        }

        CommandGroup(after: .saveItem) {
            Button("Save Request") {
                guard let state, let tab = state.selectedTab else { return }
                state.saveTab(tab)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(state?.selectedTab == nil)
        }

        CommandGroup(replacing: .textEditing) {}

        CommandMenu("Request") {
            Button("Send") {
                guard let state, let tab = state.selectedTab else { return }
                state.send(tab)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(state?.selectedTab == nil)

            Button("Cancel") {
                guard let state, let tab = state.selectedTab else { return }
                state.cancelSend(tab)
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(state?.selectedTab?.isSending != true)

            Divider()

            Button("Focus URL") { state?.focusURLField() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(state == nil)

            Divider()

            ForEach(Array(EditorTab.allCases.enumerated()), id: \.element) { index, editorTab in
                Button(editorTab.title) { state?.selectedTab?.selectedEditorTab = editorTab }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(state?.selectedTab == nil)
            }
        }

        CommandGroup(after: .windowList) {
            Button("Next Tab") { state?.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(state == nil)
            Button("Previous Tab") { state?.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(state == nil)
            // The ⌘W here is the menu's label; `AppDelegate` intercepts the keystroke itself,
            // because AppKit's File ▸ Close would otherwise win the key equivalent.
            Button("Close Tab") { state?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(state == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Toggle Response Layout") { state?.toggleResponseLayout() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(state == nil)
        }
    }
}
