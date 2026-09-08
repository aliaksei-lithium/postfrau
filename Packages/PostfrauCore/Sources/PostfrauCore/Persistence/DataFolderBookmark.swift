import Foundation

/// Turning a folder the user picked into one Postfrau can still open after a relaunch.
///
/// Inside the sandbox a path is not enough: a folder chosen in an `NSOpenPanel` is readable only
/// for as long as that launch, unless a security-scoped bookmark is stored and resolved again
/// with `startAccessingSecurityScopedResource`. Everything here is about surviving that, and
/// about degrading to the built-in folder rather than to an error when it cannot.
public enum DataFolderBookmark {
    public enum BookmarkError: Error, LocalizedError, Equatable {
        case couldNotCreate(String)
        case accessDenied(String)

        public var errorDescription: String? {
            switch self {
            case .couldNotCreate(let path):
                "Postfrau could not keep access to “\(path)”. Choose the folder again."
            case .accessDenied(let path):
                "Postfrau is not allowed to open “\(path)”. Choose the folder again."
            }
        }
    }

    /// The bookmark to store in `settings.json` for a folder the user just picked.
    public static func create(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
        } catch {
            throw BookmarkError.couldNotCreate(url.path)
        }
    }

    /// What resolving a stored bookmark produced.
    public struct Resolved: Sendable {
        public var url: URL
        /// True when the bookmark had to be rebuilt because the folder moved or was renamed.
        /// The caller stores `refreshed` in settings so the next launch does not repeat the work.
        public var isStale: Bool
        public var refreshed: Data?
        /// True when the security scope was opened and must be closed on quit.
        public var isAccessing: Bool

        public init(url: URL, isStale: Bool, refreshed: Data?, isAccessing: Bool) {
            self.url = url
            self.isStale = isStale
            self.refreshed = refreshed
            self.isAccessing = isAccessing
        }
    }

    /// Resolves a stored bookmark and opens access to it.
    ///
    /// A stale bookmark is not a failure: macOS still resolves it, and the fix is to write a fresh
    /// one. Access is opened here and stays open for the life of the process — the alternative is
    /// bracketing every read and write, which would mean a `stopAccessing` for every early return
    /// in the store.
    public static func resolve(_ bookmark: Data) throws -> Resolved {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale)
        } catch {
            throw BookmarkError.accessDenied("the folder this Mac last used")
        }

        let opened = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.path) else {
            if opened { url.stopAccessingSecurityScopedResource() }
            throw BookmarkError.accessDenied(url.path)
        }

        let refreshed = isStale ? try? create(for: url) : nil
        return Resolved(url: url, isStale: isStale, refreshed: refreshed, isAccessing: opened)
    }

    /// The data folder to run with, given what settings hold.
    ///
    /// Falls back to the default folder inside the container whenever the stored one cannot be
    /// opened, and says so through `DataFolder.status` — a missing volume or a folder the user
    /// deleted must not stop the app from starting.
    public static func folder(
        from settings: AppSettings, localRoot: URL
    ) -> (folder: DataFolder, refreshedBookmark: Data?, accessedURL: URL?) {
        let fallback = DataFolder.defaultFolder(localRoot: localRoot)
        guard let bookmark = settings.dataFolderBookmark else {
            // No bookmark, but a path: the plain-path case. A bookmark belongs to the process
            // that created it, so a second Postfrau — or the `postfrau` CLI in Phase 11 — has
            // only the path to go on. It works whenever the sandbox already allows the location
            // (inside the container, or a folder the user has granted), and reports its own
            // status honestly when it does not.
            guard let path = settings.dataFolderPath, !path.isEmpty else {
                return (fallback, nil, nil)
            }
            let folder = DataFolder(
                root: URL(filePath: path, directoryHint: .isDirectory),
                isDefault: false, needsCoordination: true)
            return (folder.refreshingStatus(), nil, nil)
        }

        do {
            let resolved = try resolve(bookmark)
            let folder = DataFolder(
                root: resolved.url, isDefault: false, needsCoordination: true)
            return (folder.refreshingStatus(), resolved.refreshed,
                    resolved.isAccessing ? resolved.url : nil)
        } catch {
            var stale = fallback
            stale.status = .staleBookmark
            return (stale, nil, nil)
        }
    }
}
