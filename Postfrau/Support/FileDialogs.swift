import AppKit
import PostfrauCore

/// Open/save panels, and the security-scoped bookmarks the sandbox needs to read a file again
/// after a relaunch.
enum FileDialogs {
    /// Asks for a file and returns a bookmark to it.
    ///
    /// The bookmark is what gets stored: a plain path would stop working the moment the app
    /// restarts, because the sandbox only grants access to what the user picked *this* launch.
    static func chooseFile(prompt: String = "Choose") -> FileReference? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return makeReference(for: url)
    }

    static func makeReference(for url: URL) -> FileReference? {
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return nil }
        return FileReference(bookmark: bookmark, displayName: url.lastPathComponent)
    }

    /// Asks where to write `data`. Returns the URL it was written to.
    @discardableResult
    static func save(_ data: Data, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }
}
