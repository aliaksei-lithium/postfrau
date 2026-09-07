import AppKit
import SwiftUI

/// Handles the one thing SwiftUI's scene lifecycle cannot: holding termination open long enough
/// to finish writing.
///
/// Autosave is debounced by 300 ms, so quitting immediately after an edit would otherwise drop it.
/// `applicationShouldTerminate` returns `.terminateLater`, the flush runs, and the reply lets the
/// app go. If the flush hangs, a watchdog replies anyway rather than wedging the quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `PostfrauApp` once the state exists.
    var state: AppState?

    /// How long a flush may take before the app quits regardless.
    private static let flushDeadline = Duration.seconds(3)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        Task {
            await withTaskGroup { group in
                group.addTask { await state.flush() }
                group.addTask { try? await Task.sleep(for: Self.flushDeadline) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--appearance dark|light` forces one appearance for this process only, so the UI can be
        // reviewed in both without changing the machine's system-wide setting. (The usual
        // `-AppleInterfaceStyle` argument-domain trick does not reach an app launched through
        // LaunchServices, which is how XCUITest starts it.)
        guard let value = AppState.launchArgument(named: "--appearance") else { return }
        switch value.lowercased() {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    /// Single-window app: clicking the Dock icon after closing the window brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }
}
