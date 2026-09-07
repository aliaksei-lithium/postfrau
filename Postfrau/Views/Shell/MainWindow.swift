import SwiftUI
import PostfrauCore

/// The one window: sidebar, tab bar, request editor, response pane, status bar.
struct MainWindow: View {
    @Environment(AppState.self) private var state
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                TabBar()
                if let tab = state.selectedTab {
                    detail(for: tab, state: state)
                } else {
                    CenteredMessage(
                        symbol: "square.on.square", title: "No open request",
                        message: "Press ⌘T to open a tab.")
                }
                StatusBar()
            }
            .navigationSplitViewColumnWidth(min: 520, ideal: 900)
        }
        .navigationTitle(state.selectedTab?.title ?? "Postfrau")
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                EnvironmentPicker()
            }
        }
        .focusedSceneValue(\.appState, state)
        .onChange(of: urlFocusRequest) { _, _ in urlFieldFocused = true }
        .confirmationDialog(
            state.tabAwaitingCloseConfirmation.map {
                "Save changes to “\($0.title)” before closing?"
            } ?? "",
            isPresented: Binding(
                get: { state.tabAwaitingCloseConfirmation != nil },
                set: { if !$0 { state.tabPendingCloseConfirmation = nil } })
        ) {
            Button("Save") { state.resolveCloseConfirmation(saving: true) }
            Button("Don't Save", role: .destructive) {
                state.resolveCloseConfirmation(saving: false)
            }
            Button("Cancel", role: .cancel) { state.tabPendingCloseConfirmation = nil }
        } message: {
            Text("Your changes will be lost if you don't save them.")
        }
    }

    @ViewBuilder
    private func detail(for tab: RequestTab, state: AppState) -> some View {
        ResizableSplit(
            axis: state.settings.responseLayout == .vertical ? .vertical : .horizontal,
            fraction: Binding(
                get: { state.requestPaneFraction },
                set: { state.requestPaneFraction = $0; state.markUIStateDirty() })
        ) {
            RequestEditor(tab: tab, urlFieldFocused: $urlFieldFocused)
        } second: {
            ResponsePane(tab: tab)
        }
    }

    /// Bumped by the ⌘L menu command to move focus into the URL field.
    private var urlFocusRequest: Int { state.urlFocusRequests }
}
