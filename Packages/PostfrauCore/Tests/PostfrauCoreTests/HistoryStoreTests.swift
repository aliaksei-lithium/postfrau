import Foundation
import Testing
@testable import PostfrauCore

@Suite("History store")
struct HistoryStoreTests {
    private func entry(
        _ index: Int,
        at date: Date = fixedDate,
        level: HistoryRecordLevel = .metadata,
        source: HistorySource = .app
    ) -> HistoryEntry {
        HistoryEntry(
            sentAt: date.addingTimeInterval(Double(index)),
            method: .get,
            resolvedURL: "https://example.com/\(index)",
            statusCode: 200,
            durationMs: Double(index),
            responseBytes: index,
            source: source,
            recordLevel: level)
    }

    @Test func writesOneFilePerEntryUnderADayFolder() async throws {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url)

        try await store.append(entry(0))
        try await store.append(entry(1))

        let days = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        #expect(days.count == 1, "both entries land in the same day folder")
        let files = try FileManager.default.contentsOfDirectory(
            atPath: temp.url.appending(path: days[0]).path)
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.hasSuffix(".json") })
    }

    @Test func readsBackNewestFirst() async throws {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url)
        for index in 0..<5 { try await store.append(entry(index)) }

        let loaded = await store.load()
        #expect(loaded.count == 5)
        #expect(loaded.first?.responseBytes == 4)
        #expect(loaded.last?.responseBytes == 0)
        #expect(await store.count() == 5)
    }

    @Test func honoursTheLoadLimit() async throws {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url)
        for index in 0..<10 { try await store.append(entry(index)) }
        #expect(await store.load(limit: 3).map(\.responseBytes) == [9, 8, 7])
    }

    @Test func spansDayFoldersInTheRightOrder() async throws {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url)
        let today = fixedDate
        let yesterday = fixedDate.addingTimeInterval(-86_400)

        try await store.append(entry(1, at: yesterday))
        try await store.append(entry(2, at: today))

        let days = try FileManager.default.contentsOfDirectory(atPath: temp.url.path).sorted()
        #expect(days.count == 2)
        #expect(await store.load().first?.responseBytes == 2, "today's entry comes first")
    }

    @Test func anEmptyStoreReadsAsNothing() async {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url)
        #expect(await store.load().isEmpty)
        #expect(await store.count() == 0)
    }

    @Test func skipsFilesItCannotDecode() async throws {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url)
        try await store.append(entry(0))

        // A half-written file, and something that is not ours at all.
        let day = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)[0]
        let folder = temp.url.appending(path: day)
        try Data("{ truncated".utf8).write(to: folder.appending(path: "000000.000-broken.json"))
        try Data("notes".utf8).write(to: folder.appending(path: "notes.txt"))

        #expect(await store.load().count == 1)
    }

    @Test func anOffEntryIsNotWrittenAtAll() async throws {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url)
        try await store.append(entry(0, level: .off))
        #expect(await store.count() == 0)
    }

    @Test func prunesToTheNewestEntriesAndTidiesEmptyDays() async throws {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url)
        for index in 0..<5 {
            try await store.append(entry(index, at: fixedDate.addingTimeInterval(-86_400 * 4)))
        }
        for index in 5..<10 { try await store.append(entry(index)) }

        await store.prune(to: 3)
        let loaded = await store.load()
        #expect(loaded.map(\.responseBytes) == [9, 8, 7])

        let days = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        #expect(days.count == 1, "the emptied day folder should be gone")
    }

    @Test func prunesAutomaticallyOnceTheIntervalIsReached() async throws {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url, maxEntries: 10)
        for index in 0..<HistoryStore.pruneInterval { try await store.append(entry(index)) }
        #expect(await store.count() == 10)
    }

    @Test func deletesASingleEntryAndClearsEverything() async throws {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url)
        let doomed = entry(1)
        try await store.append(entry(0))
        try await store.append(doomed)
        try await store.append(entry(2))

        await store.delete(id: doomed.id)
        #expect(await store.count() == 2)
        #expect(await !store.load().contains { $0.id == doomed.id })

        await store.clear()
        #expect(await store.load().isEmpty)
    }

    @Test func keepsTheWholeRecordedExchange() async throws {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url)

        var full = entry(0, level: .full)
        full.requestHeaders = [HeaderField(name: "X-A", value: "1")]
        full.responseHeaders = [HeaderField(name: "Content-Type", value: "application/json")]
        full.requestBody = RecordedBody.capped(Data(#"{"a":1}"#.utf8), cap: 1024)
        full.responseBody = RecordedBody.capped(Data(#"{"ok":true}"#.utf8), cap: 1024)
        try await store.append(full)

        let loaded = try #require(await store.load().first)
        #expect(loaded.hasRecordedExchange)
        #expect(loaded.requestHeaders?.first?.name == "X-A")
        #expect(loaded.responseBody?.text == #"{"ok":true}"#)
        #expect(loaded.recordLevel == .full)
    }

    @Test func attributionSurvivesARoundTrip() async throws {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url)
        try await store.append(entry(0, source: .agent(name: "claude")))
        try await store.append(entry(1, source: .cli))

        let loaded = await store.load()
        #expect(loaded.contains { $0.source == .agent(name: "claude") })
        #expect(loaded.contains { $0.source == .cli })
        #expect(HistorySource.agent(name: "claude").isAutomated)
        #expect(!HistorySource.app.isAutomated)
    }

    @Test func migratesALegacyJSONLLog() async throws {
        let temp = TempDirectory()
        let legacy = temp.url.appending(path: "history.jsonl")
        let encoder = Postfrau.makeEncoder(pretty: false)
        var data = Data()
        for index in 0..<3 {
            data.append(try encoder.encode(entry(index)))
            data.append(0x0A)
        }
        // A torn final line, as a crash would leave it.
        data.append(Data(#"{"id":"not-a-uu"#.utf8))
        try data.write(to: legacy)

        let store = HistoryStore(root: temp.url.appending(path: "history"))
        let migrated = await store.migrateLegacyLog(at: legacy)

        #expect(migrated == 3)
        #expect(await store.count() == 3)
        #expect(!FileManager.default.fileExists(atPath: legacy.path), "the old log is renamed")
        #expect(FileManager.default.fileExists(atPath: legacy.appendingPathExtension("migrated").path))
    }

    @Test func migratingWhenThereIsNoLegacyLogDoesNothing() async {
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url.appending(path: "history"))
        #expect(await store.migrateLegacyLog(at: temp.url.appending(path: "absent.jsonl")) == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aThousandEntriesLoadWellUnderTwoHundredMilliseconds() async throws {
        // PLAN.md §6 Phase 8: 1 000 entries must load in < 200 ms at launch.
        let temp = TempDirectory()
        let store = HistoryStore(root: temp.url, maxEntries: 2000)
        for index in 0..<1000 {
            // Spread over several days, as a real log would be.
            let day = fixedDate.addingTimeInterval(Double(index / 200) * 86_400)
            try await store.append(entry(index, at: day.addingTimeInterval(Double(index))))
        }

        let started = ContinuousClock.now
        let loaded = await store.load(limit: 1000)
        let elapsed = started.duration(to: .now)

        #expect(loaded.count == 1000)
        #expect(elapsed < .milliseconds(200), "loading 1 000 entries took \(elapsed)")
    }

    @Test func fileNamesSortInTimeOrder() {
        let early = HistoryStore.timeName(Date(timeIntervalSince1970: 1_700_000_000))
        let later = HistoryStore.timeName(Date(timeIntervalSince1970: 1_700_000_061))
        #expect(early < later)
        #expect(early.count == 10, "HHmmss.SSS")
        #expect(HistoryStore.dayFolderName(fixedDate).count == 10, "yyyy-MM-dd")
    }
}

@Suite("History redaction")
struct HistoryRedactorTests {
    @Test func blanksSensitiveHeadersEntirely() {
        let headers = [
            HeaderField(name: "Authorization", value: "Bearer secret-token"),
            HeaderField(name: "cookie", value: "session=abc"),
            HeaderField(name: "Set-Cookie", value: "session=abc"),
            HeaderField(name: "X-API-Key", value: "k"),
            HeaderField(name: "Content-Type", value: "application/json"),
        ]
        let redacted = HistoryRedactor.redact(headers: headers)
        #expect(redacted[0].value == HistoryRedactor.placeholder)
        #expect(redacted[1].value == HistoryRedactor.placeholder)
        #expect(redacted[2].value == HistoryRedactor.placeholder)
        #expect(redacted[3].value == HistoryRedactor.placeholder)
        #expect(redacted[4].value == "application/json", "ordinary headers are untouched")
    }

    @Test func replacesSecretValuesWhereverTheyAppear() {
        let secrets: Set<String> = ["s3cret-value"]
        #expect(HistoryRedactor.redact(text: "token=s3cret-value&a=1", secrets: secrets)
            == "token=•••&a=1")
        let headers = [HeaderField(name: "X-Custom", value: "prefix s3cret-value suffix")]
        #expect(HistoryRedactor.redact(headers: headers, secrets: secrets)[0].value
            == "prefix ••• suffix")
    }

    @Test func ignoresSecretsTooShortToBeMeaningful() {
        // Replacing every "1" would destroy the body while protecting nothing.
        #expect(HistoryRedactor.redact(text: "a=1&b=12", secrets: ["1", "12"]) == "a=1&b=12")
    }

    @Test func keepsTheShapeOfAuthButNotTheCredential() {
        #expect(HistoryRedactor.redact(auth: .bearer(token: "t0ken"))
            == .bearer(token: HistoryRedactor.placeholder))
        #expect(HistoryRedactor.redact(auth: .basic(username: "ada", password: "pw"))
            == .basic(username: "ada", password: HistoryRedactor.placeholder))
        #expect(HistoryRedactor.redact(auth: .apiKey(key: "X-Key", value: "v", location: .query))
            == .apiKey(key: "X-Key", value: HistoryRedactor.placeholder, location: .query))
        #expect(HistoryRedactor.redact(auth: .none) == .none)
        #expect(HistoryRedactor.redact(auth: .bearer(token: "")) == .bearer(token: ""))
    }

    @Test func redactsAWholeRequestSnapshot() {
        let request = RequestItem(
            name: "R",
            method: .post,
            url: "https://api.test/x?token=s3cret-value",
            params: [KeyValue(key: "token", value: "s3cret-value")],
            headers: [
                KeyValue(key: "Authorization", value: "Bearer s3cret-value"),
                KeyValue(key: "X-Trace", value: "keep me"),
            ],
            auth: .bearer(token: "s3cret-value"),
            body: .raw(text: #"{"token":"s3cret-value"}"#, language: .json))

        let redacted = HistoryRedactor.redact(request: request, secrets: ["s3cret-value"])
        let encoded = String(
            decoding: try! Postfrau.makeEncoder().encode(redacted), as: UTF8.self)
        #expect(!encoded.contains("s3cret-value"), "no trace of the secret anywhere")
        #expect(encoded.contains("keep me"), "harmless values survive")
        #expect(redacted.headers[0].value == HistoryRedactor.placeholder)
    }

    @Test func cappingABodyRecordsWhatWasDropped() {
        let big = Data(repeating: 0x41, count: 1000)
        let capped = RecordedBody.capped(big, cap: 100, mimeType: "text/plain")
        #expect(capped.data.count == 100)
        #expect(capped.truncated)
        #expect(capped.originalBytes == 1000)
        #expect(capped.mimeType == "text/plain")

        let small = RecordedBody.capped(Data("hi".utf8), cap: 100)
        #expect(!small.truncated)
        #expect(small.originalBytes == 2)
    }

    @Test func recordingLevelsDescribeWhatTheyKeep() {
        #expect(!HistoryRecordLevel.metadata.recordsHeaders)
        #expect(HistoryRecordLevel.headers.recordsHeaders)
        #expect(!HistoryRecordLevel.headers.recordsBodies)
        #expect(HistoryRecordLevel.full.recordsBodies)
        #expect(HistoryRecordLevel.allCases.allSatisfy { !$0.explanation.isEmpty })
    }
}
