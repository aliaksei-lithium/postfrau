import AppKit
import OSLog

/// Click-to-paint instrumentation. Silent unless `POSTFRAU_CLICK_PROBE` is set in the
/// environment, so it costs a single boolean test in a normal run.
///
/// It exists because the obvious tools answer the wrong question: `sample` and Time Profiler
/// measure CPU *busy* time, and a click that is merely being waited on is 0% busy. Both halves
/// below are wall clock.
///
/// Splits the wait into the two halves that have different causes and different fixes:
///
///   * **held** — from the hardware event to our handler running. `NSEvent.timestamp` and
///     `systemUptime` share a base, so subtracting them is the real delay between the mouse
///     coming up and SwiftUI deciding the gesture was a tap. Zero work happens in this window;
///     it is a wait, and no profiler that measures CPU can see it.
///   * **paint** — from the handler to the run loop going idle again, which is after SwiftUI has
///     rebuilt the affected bodies and Core Animation has committed. This one is work.
enum ClickProbe {
    static let isEnabled = ProcessInfo.processInfo.environment["POSTFRAU_CLICK_PROBE"] != nil

    private static let signposter = OSSignposter(
        subsystem: "com.postfrau.app", category: .pointsOfInterest)
    private static let log = Logger(subsystem: "com.postfrau.app", category: "clicks")

    private static var pending: (what: String, event: Double, handler: Double)?
    private static var bodies: [String: Int] = [:]
    private static var observer: CFRunLoopObserver?

    /// Call as `let _ = ClickProbe.body("RequestRow")` at the top of a view body to count how
    /// often that body runs between the click and the screen settling. Nothing is instrumented
    /// by default; add it where a measurement needs it and take it out again.
    static func body(_ name: String) {
        guard isEnabled, pending != nil else { return }
        bodies[name, default: 0] += 1
    }

    /// Call first thing in a handler. Labelled by the kind of event being handled, so a click
    /// and an arrow key doing the identical state change can be compared directly.
    static func marked(_ what: String) {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .leftMouseUp, .leftMouseDown: mark("\(what)-click")
        case .keyDown, .keyUp: mark("\(what)-key")
        default: break
        }
    }

    private static func mark(_ what: String) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let event = NSApp.currentEvent
        let held = (now - (event?.timestamp ?? now)) * 1000
        signposter.emitEvent("tap", "\(what, privacy: .public)")
        pending = (what, held, now)
        armObserver()
    }

    /// One `beforeWaiting` fires after the update pass that the handler's mutation triggered.
    private static func armObserver() {
        guard observer == nil else { return }
        let created = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, .max
        ) { _, _ in
            MainActor.assumeIsolated {
                guard let (what, held, handler) = pending else { return }
                pending = nil
                let paint = (ProcessInfo.processInfo.systemUptime - handler) * 1000
                let counted = bodies.sorted { $0.value > $1.value }
                    .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                bodies.removeAll()
                log.notice(
                    """
                    \(what, privacy: .public) held \(held, format: .fixed(precision: 1)) ms, \
                    paint \(paint, format: .fixed(precision: 1)) ms, \
                    total \(held + paint, format: .fixed(precision: 1)) ms \
                    | \(counted, privacy: .public)
                    """)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
        observer = created
    }
}
