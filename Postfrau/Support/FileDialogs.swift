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

extension FileDialogs {
    /// Asks for a folder to keep the workspace in.
    ///
    /// - Parameter startingAt: where the panel opens. The iCloud Drive button points it at
    ///   `Mobile Documents/com~apple~CloudDocs` so "Postfrau" can be created in one step.
    static func chooseFolder(
        prompt: String,
        message: String,
        suggestedName: String? = nil,
        startingAt: URL? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        if let suggestedName { panel.nameFieldStringValue = suggestedName }
        if let startingAt { panel.directoryURL = startingAt }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs`, when this Mac has iCloud Drive on.
    ///
    /// Resolved from the real home directory rather than `NSHomeDirectory()`, which inside the
    /// sandbox points at the app container and has no iCloud Drive under it.
    static var iCloudDriveRoot: URL? {
        let home = URL(filePath: NSHomeDirectory())
        // The container path is `<home>/Library/Containers/<bundle id>/Data`; four levels up is
        // the real home.
        let realHome = home.path.contains("/Library/Containers/")
            ? home.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            : home
        let root = realHome
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    /// Opens Finder at a folder.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
