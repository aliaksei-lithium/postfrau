import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PostfrauCore

/// The strip of open requests.
///
/// Custom rather than `TabView`: it needs a dirty dot, middle-click close, drag reordering and a
/// trailing "+" — none of which `TabView` offers on macOS.
///
/// It scrolls itself rather than sitting in a `ScrollView`, because a horizontal `ScrollView`
/// swallows horizontal mouse drags whole and so makes reordering impossible: `draggable` is never
/// asked for its payload, a `DragGesture` reports a translation of exactly zero, and neither an
/// event monitor nor an `NSPanGestureRecognizer` sees anything after the mouse goes down. Take
/// the `ScrollView` away and dragging works immediately. See `docs/decisions.md` D56.
///
/// What that costs is 40 lines: an offset this view owns, the wheel read from a local monitor
/// (scroll events, unlike drags, do reach one), and scrolling the selected tab into view from the
/// frames the strip already collects.
struct TabBar: View {
    /// The strip's own coordinate space, so tab frames are measured from the start of the row
    /// rather than from wherever it happens to be scrolled to.
    private static let space = "tab-strip"

    @Environment(AppState.self) private var state

    @State private var offset: CGFloat = 0
    @State private var viewport: CGFloat = 0
    @State private var content: CGFloat = 0
    @State private var frames: [UUID: CGRect] = [:]
    @State private var band: ClosedRange<CGFloat> = 0...0

    var body: some View {
        HStack(spacing: 0) {
            strip

            // Laid out before the strip. A `GeometryReader` has no size of its own and takes
            // everything it is offered, which left these two nothing at all — the "+" was pushed
            // clean off the end of the window.
            Divider().frame(height: 18).layoutPriority(1)

            Button {
                state.newTab()
            } label: {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New Request (⌘T)")
            .accessibilityLabel("New request tab")
            .layoutPriority(1)
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

    private var strip: some View {
        // A `GeometryReader` rather than `frame(maxWidth: .infinity)`: `fixedSize` propagates the
        // content's ideal width outwards, so the strip asked for all 3 879 points of it and there
        // was nothing left to clip against. A reader takes the space it is offered and no more.
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(state.tabs) { tab in
                    TabItem(tab: tab, isSelected: tab.id == state.selectedTabID)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: TabFrames.self,
                                    value: [tab.id: proxy.frame(in: .named(Self.space))])
                            }
                        }
                }
            }
            .coordinateSpace(.named(Self.space))
            // Natural width, so tabs keep their size and run off the end rather than squeezing.
            .fixedSize(horizontal: true, vertical: false)
            .onPreferenceChange(TabFrames.self) { frames = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { content = $0; clamp() }
            .offset(x: offset)
            .frame(width: geometry.size.width, alignment: .leading)
            .clipped()
            .onChange(of: geometry.size.width, initial: true) { _, width in
                viewport = width
                clamp()
            }
        }
        .frame(height: 32)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            band = frame.minY...max(frame.minY, frame.maxY)
        }
        .background(TabStripWheel(band: band) { delta in scroll(by: delta) })
        // Not animated. Animating this ran the strip's layout once per frame for 0.15 s on
        // *every* tab switch — about 55 ms of main-thread work, the largest single cost of
        // switching tabs — and slid the strip out from under the pointer as you clicked.
        .onChange(of: state.selectedTabID) { _, id in reveal(id) }
    }

    /// How far left the content may go before its end passes the viewport's.
    private var limit: CGFloat { min(0, viewport - content) }

    private func clamp() { offset = max(limit, min(0, offset)) }

    private func scroll(by delta: CGFloat) {
        offset = max(limit, min(0, offset + delta))
    }

    /// Brings a tab fully into view, and otherwise leaves the strip where it is — a tab already
    /// on screen should not make everything else move.
    private func reveal(_ id: UUID?) {
        guard let id, let frame = frames[id], content > 0 else { return }
        if frame.minX + offset < 0 {
            offset = -frame.minX
        } else if frame.maxX + offset > viewport {
            offset = viewport - frame.maxX
        }
        clamp()
    }
}

/// Where each tab sits within the strip, so the selected one can be brought into view.
private struct TabFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The strip's scroll wheel.
///
/// A local event monitor, because the strip is no longer a `ScrollView` and there is nothing else
/// to do it. Scroll events, unlike mouse drags, do reach a monitor. Only events over the strip
/// are taken, and those are consumed so nothing else acts on them as well.
private struct TabStripWheel: NSViewRepresentable {
    var band: ClosedRange<CGFloat>
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.start(in: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.start(in: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        var parent: TabStripWheel
        private var monitor: Any?
        private weak var window: NSWindow?

        init(_ parent: TabStripWheel) { self.parent = parent }

        func start(in view: NSView) {
            window = view.window
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when the event was ours. SwiftUI's coordinates run from the top of the window,
        /// AppKit's from the bottom, and only `y` is used here to tell the strip from the rest.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            let height = window.contentView?.bounds.height ?? window.frame.height
            guard parent.band.contains(height - event.locationInWindow.y) else { return false }
            // A trackpad swipes sideways; a wheel only turns one way, and turning it should still
            // move a horizontal strip.
            let sideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            let delta = sideways ? event.scrollingDeltaX : event.scrollingDeltaY
            // A trackpad reports points; a wheel reports lines, and three of those is a notch.
            parent.onScroll(event.hasPreciseScrollingDeltas ? delta : delta * 16)
            return true
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
        .background {
            if isSelected {
                Color(nsColor: .selectedContentBackgroundColor).opacity(0.16)
            } else if isHovering {
                Color.primary.opacity(0.08)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        // The line, not the wash, is what makes the selected tab findable at a glance — the wash
        // alone was too close to the strip behind it. Lifted a point so the strip's own hairline
        // runs under it rather than through it.
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(.tint)
                    .frame(height: 2)
                    .padding(.bottom, 1)
            }
        }
        .contentShape(.rect)
        .draggable(DraggedTab(id: tab.id))
        // Dropping on a tab puts the dragged one in its place. The order is the only ordering
        // there is, and it is kept: `moveTab` marks the UI state dirty, so it survives a relaunch.
        .dropDestination(for: DraggedTab.self) { dropped, _ in
            guard let moved = dropped.first,
                  let from = state.tabs.firstIndex(where: { $0.id == moved.id }),
                  let onto = state.tabs.firstIndex(where: { $0.id == tab.id }),
                  from != onto
            else { return false }
            state.moveTab(from: from, to: onto > from ? onto + 1 : onto)
            return true
        }
        // One tap gesture; the double click comes from the AppKit event. Pairing a `count: 2`
        // gesture with a single one makes SwiftUI hold the single action for the full
        // double-click interval — ~400 ms — before selecting. See `docs/decisions.md` D52.
        .onTapGesture {
            ClickProbe.marked("tab")
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

/// A tab being dragged along the strip.
///
/// Its own type rather than `DraggedItem`: a tab and a sidebar row are both UUIDs, and sharing a
/// type would let a request be dropped onto the strip, or a tab into a folder. Declared in
/// `project.yml` under `UTExportedTypeDeclarations` — a type the system has never been told about
/// makes `draggable` a silent no-op, which is what D55 was about.
struct DraggedTab: Codable, Transferable, Sendable {
    var id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .postfrauTab)
    }
}

extension UTType {
    nonisolated static let postfrauTab = UTType(exportedAs: "com.postfrau.open-tab")
}
