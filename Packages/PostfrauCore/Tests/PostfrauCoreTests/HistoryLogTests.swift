import Foundation
import Testing
@testable import PostfrauCore

@Suite("History log")
struct HistoryLogTests {
    private func entry(_ index: Int, at date: Date = fixedDate) -> HistoryEntry {
        HistoryEntry(
            sentAt: date.addingTimeInterval(Double(index)),
            method: .get,
            resolvedURL: "https://example.com/\(index)",
            statusCode: 200,
            durationMs: Double(index),
            responseBytes: index)
    }

    @Test func appendsAndReadsBackNewestFirst() async throws {
        let temp = TempDirectory()
        let log = HistoryLog(fileURL: temp.url.appending(path: "history.jsonl"))

        for index in 0..<5 { try await log.append(entry(index)) }

        let loaded = try await log.load()
        #expect(loaded.count == 5)
        #expect(loaded.first?.resolvedURL == "https://example.com/4")
        #expect(loaded.last?.resolvedURL == "https://example.com/0")
        #expect(try await log.count() == 5)
    }

    @Test func honoursTheLoadLimit() async throws {
        let temp = TempDirectory()
        let log = HistoryLog(fileURL: temp.url.appending(path: "history.jsonl"))
        for index in 0..<10 { try await log.append(entry(index)) }

        let recent = try await log.load(limit: 3)
        #expect(recent.map(\.responseBytes) == [9, 8, 7])
    }

    @Test func readingAMissingFileYieldsNothing() async throws {
        let temp = TempDirectory()
        let log = HistoryLog(fileURL: temp.url.appending(path: "absent.jsonl"))
        #expect(try await log.load().isEmpty)
        #expect(try await log.count() == 0)
    }

    @Test func storesOneLinePerEntry() async throws {
        let temp = TempDirectory()
        let url = temp.url.appending(path: "history.jsonl")
        let log = HistoryLog(fileURL: url)
        for index in 0..<3 { try await log.append(entry(index)) }

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 3)
        #expect(text.hasSuffix("\n"))
    }

    @Test func toleratesATruncatedFinalLine() async throws {
        let temp = TempDirectory()
        let url = temp.url.appending(path: "history.jsonl")
        let log = HistoryLog(fileURL: url)
        for index in 0..<3 { try await log.append(entry(index)) }

        // Simulate a crash mid-append.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"not-a-uu"#.utf8))
        try handle.close()

        let loaded = try await log.load()
        #expect(loaded.count == 3)
    }

    @Test func prunesToTheNewestEntries() async throws {
        let temp = TempDirectory()
        let log = HistoryLog(fileURL: temp.url.appending(path: "history.jsonl"))
        for index in 0..<20 { try await log.append(entry(index)) }

        try await log.prune(to: 5)
        let loaded = try await log.load()
        #expect(loaded.count == 5)
        #expect(loaded.map(\.responseBytes) == [19, 18, 17, 16, 15])
    }

    @Test func pruningBelowTheCapDoesNothing() async throws {
        let temp = TempDirectory()
        let log = HistoryLog(fileURL: temp.url.appending(path: "history.jsonl"))
        for index in 0..<3 { try await log.append(entry(index)) }
        try await log.prune(to: 100)
        #expect(try await log.count() == 3)
    }

    @Test func prunesAutomaticallyOnceTheIntervalIsReached() async throws {
        let temp = TempDirectory()
        let log = HistoryLog(
            fileURL: temp.url.appending(path: "history.jsonl"), maxEntries: 10)
        for index in 0..<HistoryLog.pruneInterval { try await log.append(entry(index)) }
        #expect(try await log.count() == 10)
    }

    @Test func deletesASingleEntry() async throws {
        let temp = TempDirectory()
        let log = HistoryLog(fileURL: temp.url.appending(path: "history.jsonl"))
        let doomed = entry(1)
        try await log.append(entry(0))
        try await log.append(doomed)
        try await log.append(entry(2))

        try await log.delete(id: doomed.id)
        let loaded = try await log.load()
        #expect(loaded.count == 2)
        #expect(!loaded.contains { $0.id == doomed.id })
    }

    @Test func clearsEverything() async throws {
        let temp = TempDirectory()
        let url = temp.url.appending(path: "history.jsonl")
        let log = HistoryLog(fileURL: url)
        try await log.append(entry(0))
        try await log.clear()
        #expect(try await log.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func keepsTheWholeRequestSnapshotIncludingBody() async throws {
        let temp = TempDirectory()
        let log = HistoryLog(fileURL: temp.url.appending(path: "history.jsonl"))
        let snapshot = RequestItem(
            name: "Create", method: .post, url: "https://x.test/u",
            headers: [KeyValue(key: "X-A", value: "1")],
            auth: .bearer(token: "t"),
            body: .raw(text: #"{"a":1}"#, language: .json))
        try await log.append(HistoryEntry(requestSnapshot: snapshot, error: "timed out"))

        let loaded = try await log.load()
        #expect(loaded.first?.requestSnapshot == snapshot)
        #expect(loaded.first?.error == "timed out")
        #expect(loaded.first?.statusCode == nil)
    }

    @Test func changingTheCapAffectsLaterPrunes() async throws {
        let temp = TempDirectory()
        let log = HistoryLog(fileURL: temp.url.appending(path: "history.jsonl"), maxEntries: 1000)
        for index in 0..<10 { try await log.append(entry(index)) }
        await log.setMaxEntries(4)
        try await log.prune(to: 4)
        #expect(try await log.count() == 4)
    }
}
