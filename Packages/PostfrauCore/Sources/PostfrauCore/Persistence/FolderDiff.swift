import Foundation

/// One document in the data folder, as it looks on disk right now.
public struct FolderEntry: Sendable, Hashable {
    public var url: URL
    public var modified: Date
    public var byteCount: Int
    /// Computed lazily by the differ: hashing every file on every event would be wasteful when
    /// size and mtime already say nothing changed.
    public var sha256: String?

    public init(url: URL, modified: Date, byteCount: Int, sha256: String? = nil) {
        self.url = url
        self.modified = modified
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public var path: String { url.standardizedFileURL.path }
}

/// What changed in the data folder since Postfrau last wrote to it.
public struct FolderChange: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A document Postfrau has never written appeared.
        case added
        /// A document Postfrau wrote has different bytes now.
        case modified
        /// A document Postfrau wrote is gone.
        case removed
    }

    public var url: URL
    public var kind: Kind

    public var id: String { "\(kind)-\(url.path)" }

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }

    /// The document id encoded in the file name, for the collection and environment folders.
    public var documentID: UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }
}

/// Compares what is on disk with what Postfrau last wrote.
///
/// The store fingerprints every write, so a change whose bytes hash to the recorded value is
/// Postfrau's own and is not reported — otherwise every save would come back as a foreign edit
/// and fight the editor. Anything else is a change some other process made: another Mac by way of
/// a sync client, a text editor, `git checkout`.
public enum FolderDiff {
    /// Reads the data folder, one level deep into `collections/` and `environments/` plus the
    /// top-level `globals.json`. Directory listing only — nothing is hashed here.
    public static func scan(_ folder: DataFolder) -> [FolderEntry] {
        var entries: [FolderEntry] = []
        for directory in [folder.collectionsDirectory, folder.environmentsDirectory] {
            entries.append(contentsOf: listJSON(in: directory))
        }
        if let globals = entry(at: folder.globalsFile) { entries.append(globals) }
        return entries
    }

    /// The changes between a scan and the fingerprints of what was last written.
    ///
    /// - Parameter hash: reads and hashes one file; injectable so tests can drive the
    ///   "size and date match but the bytes differ" case without touching a disk.
    public static func changes(
        scanned: [FolderEntry],
        lastWritten: [String: FileFingerprint],
        hash: (URL) -> String? = { try? AtomicFile.digest(Data(contentsOf: $0)) }
    ) -> [FolderChange] {
        var changes: [FolderChange] = []
        var seen: Set<String> = []

        for entry in scanned {
            seen.insert(entry.path)
            guard let known = lastWritten[entry.path] else {
                changes.append(FolderChange(url: entry.url, kind: .added))
                continue
            }
            // The cheap check first: a file whose size and mtime are unchanged is unchanged.
            // A sync client that rewrites a file byte-for-byte still moves its mtime, so this
            // only skips work, it does not miss edits.
            if known.byteCount == entry.byteCount && known.modified == entry.modified { continue }
            let digest = entry.sha256 ?? hash(entry.url)
            if digest != known.sha256 {
                changes.append(FolderChange(url: entry.url, kind: .modified))
            }
        }

        for (path, _) in lastWritten where !seen.contains(path) {
            changes.append(FolderChange(url: URL(filePath: path), kind: .removed))
        }

        return changes.sorted { $0.url.path < $1.url.path }
    }

    // MARK: - Listing

    private static func listJSON(in directory: URL) -> [FolderEntry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return contents.filter { $0.pathExtension == "json" }.compactMap(entry(at:))
    }

    private static func entry(at url: URL) -> FolderEntry? {
        guard let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]),
            let modified = values.contentModificationDate
        else { return nil }
        return FolderEntry(url: url, modified: modified, byteCount: values.fileSize ?? 0)
    }
}
