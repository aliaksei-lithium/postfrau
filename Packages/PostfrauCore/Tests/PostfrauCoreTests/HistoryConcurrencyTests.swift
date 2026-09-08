import Foundation
import Testing
@testable import PostfrauCore

/// PLAN.md §6 Phase 8: "two processes appending simultaneously lose nothing".
///
/// The app and the `postfrau` CLI are separate processes writing the same history folder. These
/// tests run a real second `Process` that writes entries the same way `HistoryStore.append` does —
/// whole file, unique name, temp-then-rename — while this process appends through the actor.
@Suite("History concurrent writers")
struct HistoryConcurrencyTests {
    /// A shell script that writes `count` entry files into `folder`, each temp-then-renamed so a
    /// reader never sees a partial file. Mirrors what a second Postfrau process does.
    private func writerScript(folder: URL, count: Int, tag: String) -> String {
        """
        set -e
        mkdir -p '\(folder.path)'
        i=0
        while [ $i -lt \(count) ]; do
          id=$(uuidgen)
          name=$(printf '12%04d.000' $i)-$id
          body='{"id":"'$id'","sentAt":"2023-11-14T22:13:20.000Z","method":"GET",'
          body=$body'"resolvedURL":"https://example.com/\(tag)/'$i'","statusCode":200,'
          body=$body'"durationMs":1,"responseBytes":0,"source":{"type":"cli"},"recordLevel":"metadata"}'
          printf '%s' "$body" > '\(folder.path)'/.$name.tmp
          mv '\(folder.path)'/.$name.tmp '\(folder.path)'/$name.json
          i=$((i + 1))
        done
        """
    }

    private func launchWriter(script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    @Test(.timeLimit(.minutes(1)))
    func twoProcessesAppendingAtOnceLoseNothing() async throws {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url, maxEntries: 10_000)
        let day = temp.url.appending(path: HistoryStore.dayFolderName(fixedDate))
        let each = 150

        // A second process starts writing while this one appends through the actor.
        let other = try launchWriter(
            script: writerScript(folder: day, count: each, tag: "cli"))

        for index in 0..<each {
            try await store.append(HistoryEntry(
                sentAt: fixedDate.addingTimeInterval(Double(index) / 1000),
                method: .get,
                resolvedURL: "https://example.com/app/\(index)",
                statusCode: 200,
                durationMs: 1,
                responseBytes: 0,
                source: .app,
                recordLevel: .metadata))
        }

        other.waitUntilExit()
        #expect(other.terminationStatus == 0)

        let loaded = await store.load(limit: 10_000)
        #expect(loaded.count == each * 2, "every entry from both writers survives")
        #expect(loaded.count { $0.source == .app } == each)
        #expect(loaded.count { $0.source == .cli } == each)
        #expect(Set(loaded.map(\.id)).count == each * 2, "no two entries collided on a name")
    }

    @Test(.timeLimit(.minutes(1)))
    func aReaderNeverSeesAPartialEntry() async throws {
        // Reading while another process writes must never yield a torn record — the reader either
        // sees a whole file or does not see it yet.
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url, maxEntries: 10_000)
        let day = temp.url.appending(path: HistoryStore.dayFolderName(fixedDate))

        let writer = try launchWriter(script: writerScript(folder: day, count: 300, tag: "cli"))
        var lastCount = 0
        while writer.isRunning {
            let loaded = await store.load(limit: 10_000)
            #expect(loaded.allSatisfy { $0.resolvedURL.contains("example.com") })
            lastCount = max(lastCount, loaded.count)
        }
        writer.waitUntilExit()

        #expect(await store.load(limit: 10_000).count == 300)
        #expect(lastCount > 0, "the reader did observe entries mid-write")
    }

    @Test(.timeLimit(.minutes(1)))
    func twoActorsOnTheSameFolderBothSurvive() async throws {
        // Same folder, two stores — the shape the app and an in-process CLI helper would take.
        let temp = TempDirectory()
        let app = HistoryStore(root: temp.url, maxEntries: 10_000)
        let cli = HistoryStore(root: temp.url, maxEntries: 10_000)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (store, source) in [(app, HistorySource.app), (cli, .cli)] {
                group.addTask {
                    for index in 0..<100 {
                        try await store.append(HistoryEntry(
                            sentAt: fixedDate.addingTimeInterval(Double(index) / 1000),
                            method: .post,
                            resolvedURL: "https://example.com/\(index)",
                            statusCode: 201,
                            durationMs: 1,
                            responseBytes: 0,
                            source: source,
                            recordLevel: .metadata))
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(await app.count() == 200)
    }
}
