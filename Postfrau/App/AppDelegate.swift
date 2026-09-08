import AppKit
import SwiftUI

/// Handles the parts of the app lifecycle SwiftUI's scene model does not reach.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `PostfrauApp` once the state exists.
    var state: AppState?

    /// How long a flush may take before the app quits regardless.
    private static let flushDeadline = Duration.seconds(3)

    private var closeTabMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearanceOverride()
        installCloseTabShortcut()
    }

    /// Autosave is debounced, so quitting immediately after an edit would otherwise drop it.
    /// Termination is held open until the flush finishes, with a watchdog so a stuck write cannot
    /// wedge the quit.
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

    /// Closing the window is not quitting: ⌘N (or the Dock icon) brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Single-window app: clicking the Dock icon after closing the window brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        bringMainWindowForward()
        return true
    }

    /// Activating Postfrau should show Postfrau. Becoming the active application does not by
    /// itself raise a window, so a window left behind another app's stays there — the menu bar
    /// says Postfrau while the screen shows something else.
    func applicationDidBecomeActive(_ notification: Notification) {
        bringMainWindowForward()
    }

    func bringMainWindowForward() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - ⌘W

    /// Makes ⌘W close the *tab*, as §5 specifies.
    ///
    /// A SwiftUI `Window` scene always gets a File ▸ Close item on ⌘W, and when two menu items
    /// share a key equivalent AppKit picks the system one — so ⌘W closed the whole window, which
    /// for a single-window app looked like the app quitting. Retargeting that menu item does not
    /// stick: SwiftUI rebuilds the menu and reverts it. A local key monitor runs before menu
    /// dispatch, so it is the one place the decision can actually be made.
    private func installCloseTabShortcut() {
        closeTabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "w",
                  let state = self.state,
                  // Only when a window is actually showing tabs; otherwise let ⌘W do its normal job.
                  NSApp.keyWindow != nil
            else { return event }

            state.closeSelectedTab()
            return nil  // swallowed: the File ▸ Close item must not also fire
        }
    }

    private func applyAppearanceOverride() {
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
}
