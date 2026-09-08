import SwiftUI
import PostfrauCore

/// The one window: sidebar, tab bar, request editor, response pane, status bar.
struct MainWindow: View {
    @Environment(AppState.self) private var state
    @Environment(\.undoManager) private var undoManager
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SidebarView()
        } detail: {
            // A separate view, and not for tidiness: `MainWindow`'s body owns the toolbar, the
            // sheets and the split itself, so anything it reads re-creates all of that when it
            // changes. Reading `selectedTab` here meant every tab switch rebuilt the window
            // chrome — about half of the ~120 ms a switch cost. See `docs/decisions.md` D50.
            DetailPane(urlFieldFocused: $urlFieldFocused)
                .navigationSplitViewColumnWidth(min: 520, ideal: 900)
        }
        .sheet(item: $state.importReport) { report in
            ImportReportSheet(report: report) { state.importReport = nil }
        }
        .sheet(isPresented: $state.isShortcutsPresented) {
            ShortcutsSheet { state.isShortcutsPresented = false }
        }
        .sheet(isPresented: $state.isAboutPresented) {
            AboutWindow()
                .overlay(alignment: .topTrailing) {
                    Button("Done") { state.isAboutPresented = false }
                        .keyboardShortcut(.defaultAction)
                        .padding(12)
                }
        }
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                EnvironmentPicker()
            }
        }
        .onChange(of: urlFocusRequest) { _, _ in urlFieldFocused = true }
        // The window owns the undo manager; structural sidebar edits register their steps with it.
        .onAppear { state.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in state.undoManager = manager }
        .overlay(alignment: .top) {
            if state.isQuickOpenPresented {
                QuickOpenPanel(isPresented: Binding(
                    get: { state.isQuickOpenPresented },
                    set: { state.isQuickOpenPresented = $0 }))
                .padding(.top, 60)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(2)
            }
        }
        .animation(.easeOut(duration: 0.12), value: state.isQuickOpenPresented)
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

    /// Bumped by the ⌘L menu command to move focus into the URL field.
    private var urlFocusRequest: Int { state.urlFocusRequests }
}

/// The detail column: tab bar, the selected request, status bar.
///
/// Split out of `MainWindow` so that switching tabs invalidates only this, and not the window's
/// toolbar, sheets and dialogs along with it.
private struct DetailPane: View {
    @Environment(AppState.self) private var state
    @FocusState.Binding var urlFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TabBar()
            SyncBanners()
            if let tab = state.selectedTab {
                detail(for: tab, state: state)
            } else {
                CenteredMessage(
                    symbol: "square.on.square", title: "No open request",
                    message: "Press ⌘T to open a tab.")
            }
            StatusBar()
        }
        .navigationTitle(state.selectedTab?.title ?? "Postfrau")
    }

    @ViewBuilder
    private func detail(for tab: RequestTab, state: AppState) -> some View {
        switch tab.kind {
        case .collection:
            if let subjectID = tab.subjectID {
                CollectionEditor(collectionID: subjectID)
            }
        case .folder:
            if let subjectID = tab.subjectID, let collectionID = tab.collectionID {
                FolderEditor(folderID: subjectID, collectionID: collectionID)
            }
        case .request:
            requestDetail(for: tab, state: state)
        }
    }

    @ViewBuilder
    private func requestDetail(for tab: RequestTab, state: AppState) -> some View {
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
}
