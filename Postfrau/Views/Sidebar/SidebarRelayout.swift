import AppKit
import SwiftUI

/// Re-lays out the sidebar's visible rows after a disclosure opens or closes.
///
/// `List` is an `NSTableView` underneath, and expanding a collection inserts rows into it. With
/// the expansion animation turned off (see `AppState.expansionBinding`) the table occasionally
/// keeps the old frames for rows that moved, and two groups end up drawn over each other until
/// something else forces a layout. This forces it: once on the next turn of the run loop, after
/// the table has taken the update, and once more after AppKit's own row animation would have
/// finished.
///
/// Only the rows in the visible rect are touched — a few dozen at most — so a 5 000-request
/// collection costs the same as a small one.
struct SidebarRelayout: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Read here, in a view of its own, so an expansion re-evaluates this and nothing else.
        Nudge(expanded: state.expandedIDs, filter: state.sidebarFilter)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private struct Nudge: NSViewRepresentable {
        var expanded: Set<UUID>
        var filter: String

        func makeNSView(context: Context) -> NSView { NSView() }

        func updateNSView(_ view: NSView, context: Context) {
            let coordinator = context.coordinator
            defer { coordinator.last = (expanded, filter) }
            // The first update, and any update not caused by a disclosure or the filter.
            guard let last = coordinator.last, last != (expanded, filter) else { return }
            coordinator.relayout(from: view)
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        @MainActor
        final class Coordinator {
            var last: (Set<UUID>, String)?
            private weak var table: NSTableView?
            private var generation = 0

            func relayout(from view: NSView) {
                generation &+= 1
                let current = generation
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, current == self.generation else { return }
                    self.refresh(from: view)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak view] in
                    guard let self, let view, current == self.generation else { return }
                    self.refresh(from: view)
                }
            }

            private func refresh(from view: NSView) {
                if table == nil || table?.window !== view.window {
                    table = view.window?.contentView.flatMap(Self.firstTable(in:))
                }
                guard let table else { return }
                let visible = table.rows(in: table.visibleRect)
                guard visible.length > 0 else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(
                        integersIn: visible.location..<(visible.location + visible.length)))
                }
                table.needsLayout = true
                table.needsDisplay = true
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
