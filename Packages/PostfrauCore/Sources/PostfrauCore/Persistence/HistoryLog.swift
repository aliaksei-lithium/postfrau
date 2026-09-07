import Foundation

/// Append-only local record of every send, one JSON object per line.
///
/// JSONL is used rather than one big array so appending is O(1) and a truncated write can only
/// ever cost the last entry — `load` tolerates a corrupt final line. The log is pruned to
/// `maxEntries` on load and every `pruneInterval` appends.
public actor HistoryLog {
    public static let pruneInterval = 100

    private let fileURL: URL
    private var maxEntries: Int
    private var appendsSincePrune = 0

    public init(fileURL: URL, maxEntries: Int = 1000) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
    }

    public var url: URL { fileURL }

    public func setMaxEntries(_ value: Int) {
        maxEntries = max(0, value)
    }

    /// Adds an entry. Prunes periodically so the file cannot grow without bound.
    public func append(_ entry: HistoryEntry) throws {
        let encoder = Postfrau.makeEncoder(pretty: false)
        var line = try encoder.encode(entry)
        line.append(0x0A)  // newline

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL, options: [.atomic])
        }

        appendsSincePrune += 1
        if appendsSincePrune >= Self.pruneInterval {
            try prune(to: maxEntries)
        }
    }

    /// The most recent entries, newest first.
    /// - Parameter limit: how many to return; nil means all of them (up to `maxEntries`).
    public func load(limit: Int? = nil) throws -> [HistoryEntry] {
        let entries = try readAll()
        let newestFirst = entries.reversed()
        guard let limit else { return Array(newestFirst) }
        return Array(newestFirst.prefix(limit))
    }

    public func clear() throws {
        try? FileManager.default.removeItem(at: fileURL)
        appendsSincePrune = 0
    }

    public func delete(id: UUID) throws {
        let remaining = try readAll().filter { $0.id != id }
        try rewrite(remaining)
    }

    /// Keeps only the newest `count` entries.
    public func prune(to count: Int) throws {
        let entries = try readAll()
        appendsSincePrune = 0
        guard entries.count > count else { return }
        try rewrite(Array(entries.suffix(count)))
    }

    public func count() throws -> Int {
        try readAll().count
    }

    // MARK: - Private

    /// Oldest first, matching file order. Skips lines that fail to decode — a half-written last
    /// line after a crash must not lose the whole log.
    private func readAll() throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }

        let decoder = Postfrau.makeDecoder()
        var entries: [HistoryEntry] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let entry = try? decoder.decode(HistoryEntry.self, from: Data(line)) {
                entries.append(entry)
            }
        }
        return entries
    }

    private func rewrite(_ entries: [HistoryEntry]) throws {
        let encoder = Postfrau.makeEncoder(pretty: false)
        var out = Data()
        for entry in entries {
            out.append(try encoder.encode(entry))
            out.append(0x0A)
        }
        try AtomicFile.write(out, to: fileURL, coordinated: false)
    }
}
