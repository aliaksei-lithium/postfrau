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
                .onChange(of: state.selectedTabID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
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
    var tab: RequestTab
    var isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            MethodBadge(method: tab.draft.method, size: 9)
            Text(tab.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

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
        .onTapGesture { state.selectedTabID = tab.id; state.markUIStateDirty() }
        .onHover { isHovering = $0 }
        .help(tab.draft.url.isEmpty ? tab.title : tab.draft.url)
        .contextMenu {
            Button("Close Tab") { state.closeTab(tab) }
            Button("Close Other Tabs") { state.closeOtherTabs(keeping: tab) }
        }
        .draggable(tab.id.uuidString) {
            Text(tab.title).padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let draggedID = UUID(uuidString: raw),
                  let from = state.tabs.firstIndex(where: { $0.id == draggedID }),
                  let to = state.tabs.firstIndex(where: { $0.id == tab.id })
            else { return false }
            state.moveTab(from: from, to: to > from ? to + 1 : to)
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.title)\(tab.isDirty ? ", unsaved changes" : "")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The dirty dot turns into a close button on hover — the pattern every Mac editor uses.
    @ViewBuilder
    private var closeAffordance: some View {
        if isHovering {
            Button {
                state.closeTab(tab)
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
