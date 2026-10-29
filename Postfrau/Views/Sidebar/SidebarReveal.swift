import AppKit
import SwiftUI

/// Scrolls the sidebar to its selected row when a tab asks to be revealed.
///
/// `ScrollViewReader.scrollTo` on a `List` only reaches rows that have already been built, and
/// `List` does not even tell the `NSTableView` underneath which row is selected until it has built
/// that row — so a request a few thousand rows down has no selected row to scroll to. The row is
/// therefore worked out from the model (`AppState.sidebarSelectionRow`), checked against the
/// table's row count so a mismatch does nothing rather than the wrong thing, selected in the
/// table as `PressToSelect` does on a click, and scrolled to with `scrollRowToVisible`, which
/// moves no further than it has to and not at all when the row is already on screen. Like `SidebarRelayout` it runs on the next turn of the run loop — after the
/// table has taken the new rows and the selection — and again after AppKit's row animation would
/// have finished, and once more a second later for a launch, when the table is still filling.
/// A table lookup and a scroll per pass, whatever the collection size.
struct SidebarReveal: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Read here, in a view of its own, so a reveal re-evaluates this and nothing else.
        Scroller(requests: state.sidebarRevealRequests, position: { [state] in state.sidebarSelectionRow() })
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private struct Scroller: NSViewRepresentable {
        var requests: Int
        /// Asked at scroll time, not at update time: the rows change while the folders open.
        var position: () -> (row: Int, total: Int)?

        func makeNSView(context: Context) -> NSView { NSView() }

        func updateNSView(_ view: NSView, context: Context) {
            let coordinator = context.coordinator
            defer { coordinator.last = requests }
            // A reveal asked for before this view existed — the tab restored at launch — counts
            // too; after that, only a new request does.
            guard coordinator.last.map({ $0 != requests }) ?? (requests > 0) else { return }
            coordinator.position = position
            coordinator.reveal(from: view)
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        @MainActor
        final class Coordinator {
            var last: Int?
            var position: () -> (row: Int, total: Int)? = { nil }
            private weak var table: NSTableView?
            private var generation = 0

            func reveal(from view: NSView) {
                generation &+= 1
                let current = generation
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, current == self.generation else { return }
                    self.scroll(from: view)
                }
                // Later passes for a long list, whose rows — and selection — arrive after the
                // first: at launch the table is still being filled when the first pass runs.
                for delay in [0.3, 1.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak view] in
                        guard let self, let view, current == self.generation else { return }
                        self.scroll(from: view)
                    }
                }
            }

            private func scroll(from view: NSView) {
                if table == nil || table?.window !== view.window {
                    table = view.window?.contentView.flatMap(Self.firstTable(in:))
                }
                guard let table, let (row, total) = position(), table.numberOfRows == total
                else { return }
                if table.selectedRow != row {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                table.scrollRowToVisible(row)
            }

            private static func firstTable(in view: NSView) -> NSTableView? {
                if let table = view as? NSTableView { return table }
                for child in view.subviews {
                    if let found = firstTable(in: child) { return found }
                }
                return nil
            }
        }
    }
}
