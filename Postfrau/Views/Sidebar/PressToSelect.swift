import AppKit
import SwiftUI

/// Makes a sidebar row highlight on the press rather than on the release.
///
/// `List`'s own selection acts on mouse *up*, so the highlight arrived however long the button
/// happened to be held — measured at 150 ms for an ordinary 120 ms press, against 17 ms for an
/// arrow key, which acts on key down. That gap, not any work, is what made clicking feel slow.
///
/// Doing it with a SwiftUI gesture works but costs drag-and-drop: any gesture on the row — even
/// `simultaneousGesture` — stops `draggable` ever starting. So nothing here is a gesture. A local
/// event monitor watches left mouse-downs, hands the event straight back untouched, and tells the
/// `NSTableView` underneath the list to select the row that was pressed. AppKit then draws the
/// highlight in that same pass, and `List` sets its binding on mouse-up as it always did, to the
/// row that is already highlighted. See `docs/decisions.md` D55.
struct PressToSelect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.attach(from: view, attemptsLeft: 40)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private weak var table: NSTableView?
        private var monitor: Any?

        func attach(from view: NSView, attemptsLeft: Int) {
            if let root = view.window?.contentView, let found = Self.firstTable(in: root) {
                table = found
                start()
                return
            }
            // The table does not exist until the list has laid out once, and this view is not in
            // the hierarchy at the first update.
            guard attemptsLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.attach(from: view, attemptsLeft: attemptsLeft - 1)
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.select(from: event)
                return event      // handed back untouched: nothing here consumes or delays it
            }
        }

        private func select(from event: NSEvent) {
            guard let table, event.window === table.window else { return }
            let point = table.convert(event.locationInWindow, from: nil)
            guard table.bounds.contains(point) else { return }
            let row = table.row(at: point)
            // `-1` is the space below the last row; a row that is already selected needs nothing.
            guard row >= 0, row != table.selectedRow else { return }
            // Rows a `List` will not select — collections and folders carry no `.tag` — refuse
            // here too, and the highlight simply does not move, exactly as before.
            guard table.delegate?.tableView?(table, shouldSelectRow: row) ?? true else { return }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
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
