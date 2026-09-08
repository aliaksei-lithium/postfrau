import Foundation

/// The local record of every send: one JSON file per entry.
///
/// One file per entry rather than one appended log, because the app and the `postfrau` CLI write
/// history at the same time. Appending to a shared file means interleaved writes and a torn last
/// record; writing a whole new file whose name nobody else will pick means two processes can
/// record simultaneously and neither can corrupt the other. Nothing is ever rewritten in place —
/// pruning only deletes whole files.
///
/// Files live under `history/<yyyy-MM-dd>/<HHmmss.SSS>-<uuid>.json`. The day folders keep a
/// listing cheap (loading the newest N entries reads the newest day folders and stops) and make
/// the log easy to inspect by hand.
public actor HistoryStore {
    /// How many appends before pruning happens again.
    public static let pruneInterval = 100

    private let root: URL
    private var maxEntries: Int
    private var appendsSincePrune = 0

    public init(root: URL, maxEntries: Int = 1000) {
        self.root = root
        self.maxEntries = maxEntries
    }

    public var directory: URL { root }

    public func setMaxEntries(_ value: Int) {
        maxEntries = max(0, value)
    }

    // MARK: - Writing

    /// Writes one entry. A `.off` entry is dropped rather than written.
    public func append(_ entry: HistoryEntry) throws {
        guard entry.recordLevel != .off else { return }

        let day = Self.dayFolderName(entry.sentAt)
        let folder = root.appending(path: day, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let file = folder.appending(
            path: "\(Self.timeName(entry.sentAt))-\(entry.id.uuidString).json",
            directoryHint: .notDirectory)
        try AtomicFile.write(
            Postfrau.makeEncoder(pretty: false).encode(entry), to: file, coordinated: false)

        appendsSincePrune += 1
        if appendsSincePrune >= Self.pruneInterval { prune(to: maxEntries) }
    }

    // MARK: - Reading

    /// The most recent entries, newest first.
    ///
    /// Reads day folders newest-first and stops as soon as it has enough, so asking for the latest
    /// 50 out of 10 000 costs one folder listing, not ten thousand file reads.
    public func load(limit: Int? = nil) -> [HistoryEntry] {
        let wanted = limit ?? maxEntries
        guard wanted > 0 else { return [] }

        var entries: [HistoryEntry] = []
        let decoder = Postfrau.makeDecoder()

        for day in dayFolders().reversed() {
            let files = entryFiles(in: day).sorted { $0.lastPathComponent > $1.lastPathComponent }
            for file in files {
                guard let data = try? Data(contentsOf: file),
                      let entry = try? decoder.decode(HistoryEntry.self, from: data)
                else { continue }  // a half-written or foreign file is skipped, not fatal
                entries.append(entry)
                if entries.count >= wanted { return entries }
            }
        }
        return entries
    }

    public func count() -> Int {
        dayFolders().reduce(0) { $0 + entryFiles(in: $1).count }
    }

    // MARK: - Removing

    public func delete(id: UUID) {
        let needle = "-\(id.uuidString).json"
        for day in dayFolders() {
            for file in entryFiles(in: day) where file.lastPathComponent.hasSuffix(needle) {
                try? FileManager.default.removeItem(at: file)
                return
            }
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: root)
        appendsSincePrune = 0
    }

    /// Keeps the newest `count` entries and deletes the rest, oldest first.
    public func prune(to count: Int) {
        appendsSincePrune = 0
        let days = dayFolders()

        // Walk newest-first, keeping a budget; everything past it goes.
        var budget = max(0, count)
        for day in days.reversed() {
            let files = entryFiles(in: day).sorted { $0.lastPathComponent > $1.lastPathComponent }
            for file in files {
                if budget > 0 {
                    budget -= 1
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            // An emptied day folder is tidied away so listings stay cheap.
            if entryFiles(in: day).isEmpty { try? FileManager.default.removeItem(at: day) }
        }
    }

    // MARK: - Migration

    /// Moves a pre-existing `history.jsonl` into per-entry files, once.
    ///
    /// Earlier builds appended to a single JSONL file. Rather than lose that history, each line
    /// becomes a file; the old log is renamed rather than deleted, so nothing is destroyed if the
    /// migration turns out to be wrong.
    /// - Returns: how many entries were migrated.
    @discardableResult
    public func migrateLegacyLog(at url: URL) -> Int {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return 0 }

        let decoder = Postfrau.makeDecoder()
        var migrated = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let entry = try? decoder.decode(HistoryEntry.self, from: Data(line)) else { continue }
            if (try? append(entry)) != nil { migrated += 1 }
        }
        try? FileManager.default.moveItem(
            at: url, to: url.appendingPathExtension("migrated"))
        return migrated
    }

    // MARK: - Layout

    /// `2026-09-08`
    static func dayFolderName(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// `142317.482` — sorts lexicographically in time order within a day.
    static func timeName(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let milliseconds = (parts.nanosecond ?? 0) / 1_000_000
        return String(
            format: "%02d%02d%02d.%03d",
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, milliseconds)
    }

    /// Day folders in ascending date order.
    private func dayFolders() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func entryFiles(in day: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: day, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents.filter { $0.pathExtension == "json" }
    }
}
