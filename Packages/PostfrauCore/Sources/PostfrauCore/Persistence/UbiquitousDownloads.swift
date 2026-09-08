import Foundation

/// Pulling iCloud Drive placeholders down so the workspace can actually be read.
///
/// A file in iCloud Drive that has not been downloaded to this Mac is present only as a
/// placeholder — the real name is `.Acme.json.icloud` and the visible one does not open. Postfrau
/// asks for those on launch instead of reporting them as unreadable files.
public enum UbiquitousDownloads {
    /// A document that is still coming down from iCloud.
    public struct Pending: Sendable, Hashable {
        public var url: URL
        public var documentID: UUID?
        /// 0–100, or nil while iCloud has not reported any progress yet.
        public var percentDownloaded: Double?

        public init(url: URL, documentID: UUID?, percentDownloaded: Double?) {
            self.url = url
            self.documentID = documentID
            self.percentDownloaded = percentDownloaded
        }
    }

    /// Requests every not-yet-downloaded document in the folder, and reports what is on its way.
    ///
    /// Safe to call on a folder that is not in iCloud at all: nothing there is ubiquitous, so the
    /// scan finds nothing and no request is made.
    @discardableResult
    public static func requestAll(in folder: DataFolder) -> [Pending] {
        var pending: [Pending] = []
        for directory in [folder.collectionsDirectory, folder.environmentsDirectory] {
            pending.append(contentsOf: request(in: directory))
        }
        pending.append(contentsOf: request(at: folder.globalsFile))
        return pending
    }

    private static func request(in directory: URL) -> [Pending] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants])) ?? []
        return contents.flatMap(request(at:))
    }

    /// The placeholder for `Acme.json` is the hidden `.Acme.json.icloud` beside it, so both the
    /// visible name and the placeholder name have to be understood.
    private static func request(at url: URL) -> [Pending] {
        let target = url.lastPathComponent.hasSuffix(".icloud") ? visibleURL(for: url) : url
        guard let values = try? url.resourceValues(forKeys: Set(keys)),
              values.isUbiquitousItem == true
        else { return [] }

        let status = values.ubiquitousItemDownloadingStatus
        guard status != .current else { return [] }

        try? FileManager.default.startDownloadingUbiquitousItem(at: target)
        return [Pending(
            url: target,
            documentID: UUID(uuidString: target.deletingPathExtension().lastPathComponent),
            percentDownloaded: nil)]
    }

    /// `/x/.Acme.json.icloud` → `/x/Acme.json`
    static func visibleURL(for placeholder: URL) -> URL {
        var name = placeholder.lastPathComponent
        if name.hasSuffix(".icloud") { name.removeLast(".icloud".count) }
        if name.hasPrefix(".") { name.removeFirst() }
        return placeholder.deletingLastPathComponent().appending(path: name, directoryHint: .notDirectory)
    }

    private static let keys: [URLResourceKey] = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey,
    ]
}
