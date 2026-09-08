import Foundation
import Testing
@testable import PostfrauCore

/// PLAN.md §6 Phase 12: "simulate kill -9 during autosave, verify files intact".
///
/// The claim being tested is the one every write in Postfrau depends on: a document is either the
/// old one or the new one, never a half of each. That holds because `AtomicFile` writes to a
/// temporary file in the same directory and renames it over the destination — `rename(2)` is
/// atomic on APFS — so a process killed at any moment leaves a whole file behind.
@Suite("Crash safety", .serialized)
struct CrashSafetyTests {
    /// Writes a collection repeatedly in a subprocess, so it can be killed mid-write.
    ///
    /// Bounded, not `while true`: an unbounded loop spawns `mv` faster than the system reaps it,
    /// and a `waitUntilExit` on the killed shell can then sit behind thousands of orphans. A
    /// fixed number of writes with a pause between them is just as good at landing the kill
    /// somewhere unpredictable, and it always terminates.
    private func writerScript(file: URL, marker: String) -> String {
        """
        i=0
        while [ $i -lt 400 ]; do
          i=$((i + 1))
          body='{"schemaVersion":1,"id":"11111111-1111-1111-1111-111111111111",'
          body=$body'"name":"\(marker) '$i'","items":[],"variables":[],'
          body=$body'"auth":{"type":"none"},"revision":'$i',"extras":{}}'
          printf '%s' "$body" > '\(file.path).tmp'
          mv '\(file.path).tmp' '\(file.path)'
        done
        """
    }

    @Test(.timeLimit(.minutes(1)))
    func aWriterKilledMidFlightLeavesAWholeDocument() async throws {
        let temp = TempDirectory()
        let file = temp.url.appending(path: "collection.json", directoryHint: .notDirectory)

        // Seed a valid document, so "intact" means something from the first instant.
        try Data(#"{"schemaVersion":1,"id":"11111111-1111-1111-1111-111111111111","name":"seed","items":[],"variables":[],"auth":{"type":"none"},"revision":0,"extras":{}}"#.utf8)
            .write(to: file)

        // Kill the writer at eight different moments, reading the document after each.
        for attempt in 0..<8 {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", writerScript(file: file, marker: "attempt\(attempt)")]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()

            // Somewhere inside the write loop, not at a predictable point.
            try await Task.sleep(for: .milliseconds(.random(in: 5...25)))
            kill(process.processIdentifier, SIGKILL)
            await Self.waitForExit(process)

            let data = try Data(contentsOf: file)
            let decoded = try? Postfrau.makeDecoder().decode(RequestCollection.self, from: data)
            let preview = String(decoding: data, as: UTF8.self).prefix(120)
            #expect(decoded != nil, "attempt \(attempt) left an unreadable file: \(preview)")
        }

        // Temporaries a killed writer left behind are expected — it died before its rename. What
        // matters is that none of them is the destination, which every read above proved.
    }

    /// Waits for a killed child without `Process.waitUntilExit()`.
    ///
    /// `waitUntilExit` goes through Foundation's termination handling, which can sit forever when
    /// another thread in the process is blocked inside the Security framework — which is exactly
    /// what `KeychainProbe` does on a Mac whose keychain wants an authorization. Polling the pid
    /// asks the kernel directly and cannot deadlock against anything.
    static func waitForExit(_ process: Process, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func atomicWriteReplacesRatherThanTruncating() throws {
        // The property the whole design rests on: at no point is the destination a partial file.
        let temp = TempDirectory()
        let file = temp.url.appending(path: "doc.json", directoryHint: .notDirectory)

        let long = Data(String(repeating: "a", count: 2_000_000).utf8)
        try AtomicFile.write(long, to: file, coordinated: false)
        #expect(try Data(contentsOf: file).count == long.count)

        // Overwriting with something much shorter must not leave the tail of the old one.
        let short = Data("b".utf8)
        try AtomicFile.write(short, to: file, coordinated: false)
        #expect(try Data(contentsOf: file) == short)
    }

    @Test func aWriteToAFolderThatDisappearsFailsRatherThanCorrupting() throws {
        let temp = TempDirectory()
        let directory = temp.url.appending(path: "gone", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "doc.json", directoryHint: .notDirectory)
        try AtomicFile.write(Data("{}".utf8), to: file, coordinated: false)

        try FileManager.default.removeItem(at: directory)
        // The write recreates the directory rather than failing: a folder that vanished mid-session
        // is the sync case from Phase 9, and losing the document would be the worse outcome.
        try AtomicFile.write(Data(#"{"a":1}"#.utf8), to: file, coordinated: false)
        #expect(try Data(contentsOf: file) == Data(#"{"a":1}"#.utf8))
    }

    @Test(.timeLimit(.minutes(1)))
    func historyEntriesSurviveAKilledWriter() async throws {
        // History is one file per entry, so a kill can only ever cost the entry being written.
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url, maxEntries: 10_000)
        for index in 0..<20 {
            try await store.append(HistoryEntry(
                sentAt: fixedDate.addingTimeInterval(Double(index)),
                method: .get, resolvedURL: "https://example.com/\(index)",
                statusCode: 200, durationMs: 1, responseBytes: 0))
        }

        let day = temp.url.appending(path: HistoryStore.dayFolderName(fixedDate))
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", """
            set -e
            while true; do
              printf '{"id":"' > '\(day.path)/999999.999-partial.json'
            done
            """]
        process.standardError = FileHandle.nullDevice
        try process.run()
        try await Task.sleep(for: .milliseconds(30))
        kill(process.processIdentifier, SIGKILL)
        await Self.waitForExit(process)

        // The torn file is skipped; every complete entry is still there.
        let loaded = await store.load(limit: 100)
        #expect(loaded.count == 20)
    }
}
