import SwiftUI
import PostfrauCore

/// The scrollable strip of open requests.
///
/// Custom rather than `TabView`: it needs a dirty dot, middle-click close, drag reordering and a
/// trailing "+" — none of which `TabView` offers on macOS.
struct TabBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(state.tabs) { tab in
                            TabItem(tab: tab, isSelected: tab.id == state.selectedTabID)
                                .id(tab.id)
                        }
                    }
                }
                .scrollIndicators(.never)
                // Not animated, and not centred.
                //
                // Animating this ran the strip's layout once per frame for 0.15 s on *every* tab
                // switch — about 55 ms of main-thread work, the single largest cost of switching
                // tabs. `anchor: nil` also means a tab already on screen is left where it is,
                // rather than the strip sliding out from under the pointer when you click one.
                .onChange(of: state.selectedTabID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }

            Divider().frame(height: 18)

            Button {
                state.newTab()
            } label: {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New Request (⌘T)")
            .accessibilityLabel("New request tab")
        }
        .frame(height: 32)
        // The double-click-to-open-a-tab gesture lives in the background rather than on the bar
        // itself: a gesture on the container makes SwiftUI collapse every tab into one
        // accessibility element, which breaks VoiceOver and XCUITest alike.
        .background {
            Color(nsColor: .windowBackgroundColor)
                .contentShape(.rect)
                .onTapGesture(count: 2) { state.newTab() }
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }
}

struct TabItem: View {
    @Environment(AppState.self) private var state
    @Bindable var tab: RequestTab
    var isSelected: Bool

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            MethodBadge(method: tab.draft.method, size: 9)
            if isRenaming {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRename() } }
                    .accessibilityLabel("Rename request")
            } else {
                Text(tab.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            closeAffordance
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(minWidth: 110, maxWidth: 220)
        .background(isSelected ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.clear))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .contentShape(.rect)
        // One tap gesture; the double click comes from the AppKit event. Pairing a `count: 2`
        // gesture with a single one makes SwiftUI hold the single action for the full
        // double-click interval — ~400 ms — before selecting. See `docs/decisions.md` D52.
        .onTapGesture {
            if NSApp.currentEvent?.clickCount == 2 {
                beginRename()
            } else {
                state.selectedTabID = tab.id
                state.markUIStateDirty()
            }
        }
        .onHover { isHovering = $0 }
        .help(tab.draft.url.isEmpty ? tab.title : tab.draft.url)
        .contextMenu {
            Button("Rename…") { beginRename() }
            Divider()
            Button("Close Tab") { requestClose() }
            Button("Close Other Tabs") { state.closeOtherTabs(keeping: tab) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.title)\(tab.isDirty ? ", unsaved changes" : "")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Closing a tab with unsaved work asks first. The dialog belongs to the window, not to this
    /// row: presenting it from a view that is about to be removed is a good way to crash.
    private func requestClose() {
        if state.closingLosesWork(tab) {
            state.tabPendingCloseConfirmation = tab.id
        } else {
            state.closeTab(tab)
        }
    }

    private func beginRename() {
        draftName = tab.draft.name
        isRenaming = true
        renameFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        state.rename(tab, to: draftName)
    }

    /// The dirty dot turns into a close button on hover — the pattern every Mac editor uses.
    @ViewBuilder
    private var closeAffordance: some View {
        if isHovering {
            Button {
                requestClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title)")
        } else if tab.isDirty {
            Circle()
                .fill(.secondary)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: 14, height: 14)
        }
    }
}
