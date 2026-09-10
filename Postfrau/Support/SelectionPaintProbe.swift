import AppKit
import OSLog
import SwiftUI

/// Times a click to the commit in which the row highlight actually changes.
///
/// Silent unless `POSTFRAU_CLICK_PROBE` is set. It exists because every other measurement to hand
/// reports when *state* settles, which is not what anyone looks at. `List` is an `NSTableView`
/// underneath, and that view redraws its highlight in the commit where its own `selectedRow`
/// changes — so watching that value once per commit, against the timestamp of the mouse event
/// that caused it, is the moment the selection appears on screen.
enum SelectionPaintProbe {
    private static let log = Logger(subsystem: "com.postfrau.app", category: "clicks")
    private static weak var table: NSTableView?
    private static var lastRow = -1
    private static var pressedAt: Double?
    private static var releasedAt: Double?
    private static var monitor: Any?
    private static var observer: CFRunLoopObserver?

    static func watch(_ table: NSTableView) {
        guard ClickProbe.isEnabled, self.table !== table else { return }
        self.table = table
        lastRow = table.selectedRow
        startMonitor()
        startObserver()
    }

    private static func startMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) {
            event in
            if event.type == .leftMouseDown { pressedAt = event.timestamp; releasedAt = nil }
            else { releasedAt = event.timestamp }
            return event   // passed straight through; nothing here consumes or delays it
        }
    }

    private static func startObserver() {
        guard observer == nil else { return }
        let created = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, .max
        ) { _, _ in
            MainActor.assumeIsolated {
                guard let table else { return }
                guard table.selectedRow != lastRow else { return }
                lastRow = table.selectedRow
                guard let pressedAt else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let fromDown = (now - pressedAt) * 1000
                let fromUp = releasedAt.map { (now - $0) * 1000 } ?? -1
                self.pressedAt = nil
                log.notice(
                    """
                    highlight painted \(fromDown, format: .fixed(precision: 1)) ms after down, \
                    \(fromUp, format: .fixed(precision: 1)) ms after up
                    """)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
        observer = created
    }
}

/// Finds the `NSTableView` behind a `List` and hands it to the probe.
///
/// Searched from the window rather than up our own superview chain, and retried: at the first
/// `updateNSView` this view is usually not in the hierarchy yet, and the table does not exist
/// until the list has laid out once.
struct SelectionPaintWatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard ClickProbe.isEnabled else { return }
        find(from: view, attemptsLeft: 40)
    }

    private func find(from view: NSView, attemptsLeft: Int) {
        if let root = view.window?.contentView, let table = Self.firstTable(in: root) {
            SelectionPaintProbe.watch(table)
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            find(from: view, attemptsLeft: attemptsLeft - 1)
        }
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let found = firstTable(in: child) { return found }
        }
        return nil
    }
}
