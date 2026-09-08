import Foundation

/// What to do about one foreign change to a document.
public enum ConflictOutcome: Sendable, Hashable {
    /// No local edits were pending: the foreign version is simply adopted.
    case reloaded
    /// Local edits were pending: they are kept, and the foreign version is written to
    /// `conflicts/` so nothing is lost.
    case conflicted(copy: URL)
    /// The document is gone from the folder.
    case removed
}

/// Decides what a foreign change means for a document, and where a losing version is parked.
///
/// The rule is that Postfrau never discards work. A foreign change to something the user is not
/// editing is adopted silently — that is what sync is for. A foreign change to something with
/// unsaved edits keeps the local copy on screen and writes the other side to a conflict file, so
/// the user chooses at their own pace instead of in a modal.
public enum ConflictResolver {
    /// `Acme API-marys-macbook-2026-09-08-142317.json`
    ///
    /// Host and timestamp are in the name because two Macs can produce a conflict for the same
    /// document minutes apart, and a bare `-conflict` suffix would have them overwrite each other.
    public static func conflictFileName(
        documentName: String,
        host: String,
        date: Date,
        fileExtension: String = "json"
    ) -> String {
        let stem = sanitize(documentName.isEmpty ? "Untitled" : documentName)
        let hostPart = sanitize(host.replacingOccurrences(of: ".local", with: ""))
        return "\(stem)-\(hostPart)-\(timestamp(date)).\(fileExtension)"
    }

    /// Writes the version that lost to `conflicts/`, and returns where it went.
    @discardableResult
    public static func writeConflictCopy(
        _ data: Data,
        documentName: String,
        in directory: URL,
        host: String = ProcessInfo.processInfo.hostName,
        date: Date = Date()
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appending(
            path: conflictFileName(documentName: documentName, host: host, date: date),
            directoryHint: .notDirectory)
        // Two conflicts in the same second are rare but not impossible; never overwrite one.
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(
                path: conflictFileName(
                    documentName: "\(documentName) \(suffix)", host: host, date: date),
                directoryHint: .notDirectory)
            suffix += 1
        }
        try AtomicFile.write(data, to: url, coordinated: false)
        return url
    }

    /// True when Apple's own conflict versions should be ignored.
    ///
    /// iCloud parks its losing versions beside the file with a name like `Acme API 2.json`, and
    /// `NSFileVersion` exposes them separately. Postfrau makes its own copies with a name that
    /// says which Mac they came from, so adopting Apple's as new documents would duplicate every
    /// conflict twice over.
    public static func isSystemConflictVersion(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        // `<uuid> 2` — a document name Postfrau writes is a bare UUID and never has a suffix.
        guard let space = stem.lastIndex(of: " ") else { return false }
        let head = String(stem[stem.startIndex..<space])
        let tail = String(stem[stem.index(after: space)...])
        return UUID(uuidString: head) != nil && Int(tail) != nil
    }

    /// `2026-09-08-142317`
    static func timestamp(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Keeps a file name usable on every filesystem the data folder might live on.
    static func sanitize(_ text: String) -> String {
        let cleaned = text
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\u{0}"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(60))
    }
}
