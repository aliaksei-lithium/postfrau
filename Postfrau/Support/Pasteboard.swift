import AppKit

/// The general pasteboard, wrapped so call sites do not each repeat the clear/declare dance.
enum Pasteboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The current clipboard text, if there is any.
    static var text: String? {
        NSPasteboard.general.string(forType: .string)
    }
}
