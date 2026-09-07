import Foundation

/// The synced root: where collections, environments and globals live.
///
/// The user can point this at any folder — typically one inside iCloud Drive, Google Drive or
/// Dropbox — so a sync client, not Postfrau, moves the bytes between Macs. Everything written
/// here is atomic, file-coordinated and one-document-per-file so a half-copied folder is never
/// a corrupt workspace.
public struct DataFolder: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case ok
        /// The folder resolved but does not exist on disk (unmounted volume, deleted folder).
        case missing
        /// The folder exists but cannot be read or written.
        case unreadable(String)
        /// The stored bookmark no longer resolves; Postfrau fell back to the default location.
        case staleBookmark
    }

    public var root: URL
    public var status: Status
    /// True when the folder is the built-in default rather than one the user chose.
    public var isDefault: Bool
    /// True when writes must be file-coordinated (any user-chosen folder, which may be synced).
    public var needsCoordination: Bool

    public init(root: URL, status: Status = .ok, isDefault: Bool = false, needsCoordination: Bool = true) {
        self.root = root
        self.status = status
        self.isDefault = isDefault
        self.needsCoordination = needsCoordination
    }

    public var collectionsDirectory: URL { root.appending(path: "collections", directoryHint: .isDirectory) }
    public var environmentsDirectory: URL { root.appending(path: "environments", directoryHint: .isDirectory) }
    public var globalsFile: URL { root.appending(path: "globals.json", directoryHint: .notDirectory) }
    public var markerFile: URL { root.appending(path: "postfrau-workspace.json", directoryHint: .notDirectory) }

    public func collectionFile(_ id: UUID) -> URL {
        collectionsDirectory.appending(path: "\(id.uuidString).json", directoryHint: .notDirectory)
    }

    public func environmentFile(_ id: UUID) -> URL {
        environmentsDirectory.appending(path: "\(id.uuidString).json", directoryHint: .notDirectory)
    }

    /// The sync service the folder appears to live in, for the Settings badge.
    public var provider: Provider { Provider.detect(root) }

    public enum Provider: String, Sendable, Hashable {
        case iCloudDrive, googleDrive, dropbox, oneDrive, plain

        public var displayName: String {
            switch self {
            case .iCloudDrive: "iCloud Drive"
            case .googleDrive: "Google Drive"
            case .dropbox: "Dropbox"
            case .oneDrive: "OneDrive"
            case .plain: "Local folder"
            }
        }

        public var symbolName: String {
            switch self {
            case .iCloudDrive: "icloud"
            case .googleDrive, .dropbox, .oneDrive: "arrow.triangle.2.circlepath.circle"
            case .plain: "folder"
            }
        }

        static func detect(_ url: URL) -> Provider {
            let path = url.path
            if path.contains("Mobile Documents/com~apple~CloudDocs") { return .iCloudDrive }
            if path.contains("CloudStorage/GoogleDrive-") { return .googleDrive }
            if path.contains("CloudStorage/Dropbox") || path.contains("/Dropbox/") { return .dropbox }
            if path.contains("CloudStorage/OneDrive") { return .oneDrive }
            return .plain
        }
    }

    /// Creates `collections/` and `environments/` and writes the marker file if it is missing.
    /// Returns the marker, whether it was just created or already there.
    @discardableResult
    public func prepare() throws -> WorkspaceMarker {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: collectionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: environmentsDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: markerFile.path) {
            let data = try AtomicFile.read(markerFile, coordinated: needsCoordination)
            if let marker = try? Postfrau.makeDecoder().decode(WorkspaceMarker.self, from: data) {
                return marker
            }
        }
        let marker = WorkspaceMarker()
        try AtomicFile.write(
            Postfrau.makeEncoder().encode(marker), to: markerFile, coordinated: needsCoordination)
        return marker
    }

    /// True when the folder already holds a Postfrau workspace.
    public var containsWorkspace: Bool {
        FileManager.default.fileExists(atPath: markerFile.path)
    }

    /// True when the folder has no visible entries — the "move my data here" case.
    public var isEmptyDirectory: Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return contents.isEmpty
    }

    /// Re-reads the folder's health. Cheap enough to call whenever the UI wants to show status.
    public func refreshingStatus() -> DataFolder {
        var copy = self
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            copy.status = .missing
            return copy
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            copy.status = .unreadable("The folder is not writable.")
            return copy
        }
        copy.status = .ok
        return copy
    }

    /// `~/Library/Application Support/Postfrau/Data` inside the app container.
    public static func defaultFolder(localRoot: URL) -> DataFolder {
        DataFolder(
            root: localRoot.appending(path: "Data", directoryHint: .isDirectory),
            isDefault: true,
            // The default folder is inside the sandbox container; nothing else touches it.
            needsCoordination: false)
    }

    /// `~/Library/Application Support/Postfrau` — machine-local state that never syncs.
    public static func defaultLocalRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return base.appending(path: "Postfrau", directoryHint: .isDirectory)
    }
}
