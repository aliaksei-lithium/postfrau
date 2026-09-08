import SwiftUI
import PostfrauCore

/// Help ▸ Keyboard Shortcuts.
///
/// One list, grouped the way the menus are, because the fastest way to learn a keyboard-first app
/// is to see the whole keyboard at once rather than opening five menus.
struct ShortcutsSheet: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.headline)
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Shortcut.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(group.shortcuts, id: \.name) { shortcut in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(shortcut.name)
                                    Spacer(minLength: 24)
                                    Text(shortcut.keys)
                                        .font(.body.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(shortcut.name), \(shortcut.spokenKeys)")
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 520)
    }
}

/// One shortcut, and the groups they fall into.
struct Shortcut {
    var name: String
    var keys: String

    /// VoiceOver reads "⌘⇧K" as nothing useful, so the symbols are spelled out for it.
    var spokenKeys: String {
        keys
            .replacingOccurrences(of: "⌘", with: "command ")
            .replacingOccurrences(of: "⇧", with: "shift ")
            .replacingOccurrences(of: "⌥", with: "option ")
            .replacingOccurrences(of: "⌃", with: "control ")
            .replacingOccurrences(of: "↩", with: "return")
            .replacingOccurrences(of: "⌫", with: "delete")
    }

    struct Group {
        var title: String
        var shortcuts: [Shortcut]
    }

    static let groups: [Group] = [
        Group(title: "Requests", shortcuts: [
            Shortcut(name: "New request", keys: "⌘N"),
            Shortcut(name: "New tab", keys: "⌘T"),
            Shortcut(name: "New collection", keys: "⌘⇧N"),
            Shortcut(name: "Save request", keys: "⌘S"),
            Shortcut(name: "Send", keys: "⌘↩"),
            Shortcut(name: "Cancel a send", keys: "Esc"),
            Shortcut(name: "Copy as cURL", keys: "⌘⇧C"),
        ]),
        Group(title: "Moving around", shortcuts: [
            Shortcut(name: "Quick open", keys: "⌘K"),
            Shortcut(name: "Focus the URL field", keys: "⌘L"),
            Shortcut(name: "Find in the response", keys: "⌘F"),
            Shortcut(name: "Next tab", keys: "⌘⇧]"),
            Shortcut(name: "Previous tab", keys: "⌘⇧["),
            Shortcut(name: "Close tab", keys: "⌘W"),
        ]),
        Group(title: "The request editor", shortcuts: [
            Shortcut(name: "Params", keys: "⌘1"),
            Shortcut(name: "Headers", keys: "⌘2"),
            Shortcut(name: "Auth", keys: "⌘3"),
            Shortcut(name: "Body", keys: "⌘4"),
            Shortcut(name: "Settings", keys: "⌘5"),
        ]),
        Group(title: "Windows and panes", shortcuts: [
            Shortcut(name: "Environments", keys: "⌘E"),
            Shortcut(name: "Settings", keys: "⌘,"),
            Shortcut(name: "Response beside or below", keys: "⌘⌥R"),
            Shortcut(name: "Show history", keys: "⌘⇧H"),
        ]),
        Group(title: "Editing", shortcuts: [
            Shortcut(name: "Undo", keys: "⌘Z"),
            Shortcut(name: "Redo", keys: "⌘⇧Z"),
            Shortcut(name: "Import", keys: "⌘⇧I"),
        ]),
    ]
}

/// The About window: what this is, and what it is built on.
struct AboutWindow: View {
    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
            }
            Text("Postfrau").font(.title.weight(.semibold))
            Text("Version \(Postfrau.appVersion)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("An HTTP client for macOS. Your collections are JSON files in a folder you "
                 + "choose; nothing is uploaded anywhere.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)

            Text("MIT licensed. Built with Swift and SwiftUI, and nothing else.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 340)
    }
}
