import CryptoKit
import Foundation

/// What we last wrote to a file, so a later change can be recognised as ours or foreign.
public struct FileFingerprint: Sendable, Hashable, Codable {
    public var revision: Int
    public var modified: Date
    public var sha256: String
    public var byteCount: Int

    public init(revision: Int, modified: Date, sha256: String, byteCount: Int) {
        self.revision = revision
        self.modified = modified
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

/// Atomic, optionally file-coordinated file IO.
///
/// Every write lands as a complete file: the bytes go to a temporary file in the *same*
/// directory and are then renamed over the destination, so a sync client that copies the
/// folder mid-write can never see a half-written document. Writes inside the data folder are
/// additionally wrapped in `NSFileCoordinator` so iCloud Drive and friends are told about them.
public enum AtomicFile {
    /// Writes `data` to `url`, replacing any existing file.
    /// - Parameter coordinated: wrap the write in `NSFileCoordinator` (use inside the data folder).
    @discardableResult
    public static func write(_ data: Data, to url: URL, coordinated: Bool) throws -> FileFingerprint {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if coordinated {
            var coordinatorError: NSError?
            var writeError: (any Error)?
            NSFileCoordinator(filePresenter: nil)
                .coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { target in
                    do { try writeAtomically(data, to: target) } catch { writeError = error }
                }
            if let coordinatorError { throw coordinatorError }
            if let writeError { throw writeError }
        } else {
            try writeAtomically(data, to: url)
        }
        return try fingerprint(of: url, data: data, revision: 0)
    }

    /// Reads a file, coordinating the read when it lives in the data folder.
    public static func read(_ url: URL, coordinated: Bool) throws -> Data {
        guard coordinated else { return try Data(contentsOf: url) }
        var coordinatorError: NSError?
        var readError: (any Error)?
        var out = Data()
        NSFileCoordinator(filePresenter: nil)
            .coordinate(readingItemAt: url, options: [], error: &coordinatorError) { target in
                do { out = try Data(contentsOf: target) } catch { readError = error }
            }
        if let coordinatorError { throw coordinatorError }
        if let readError { throw readError }
        return out
    }

    /// Removes a file, coordinating the delete when it lives in the data folder.
    public static func remove(_ url: URL, coordinated: Bool) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard coordinated else { return try FileManager.default.removeItem(at: url) }
        var coordinatorError: NSError?
        var removeError: (any Error)?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { target in
                do { try FileManager.default.removeItem(at: target) } catch { removeError = error }
            }
        if let coordinatorError { throw coordinatorError }
        if let removeError { throw removeError }
    }

    /// The hex SHA-256 of some bytes.
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The fingerprint of a file that currently holds `data`.
    public static func fingerprint(of url: URL, data: Data, revision: Int) throws -> FileFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes[.modificationDate] as? Date ?? Date()
        return FileFingerprint(
            revision: revision, modified: modified,
            sha256: digest(data), byteCount: data.count)
    }

    /// Reads a file and fingerprints it in one pass.
    public static func fingerprint(of url: URL, coordinated: Bool, revision: Int = 0) throws -> FileFingerprint {
        let data = try read(url, coordinated: coordinated)
        return try fingerprint(of: url, data: data, revision: revision)
    }

    // MARK: - Private

    /// Writes to a sibling temp file and renames it over the destination.
    ///
    /// `Data.write(options: .atomic)` does the same thing, but doing it by hand lets us keep the
    /// destination's directory (important for `NSFileCoordinator`, which hands us a *different*
    /// URL to write to) and gives a clear place to hook failure handling.
    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
