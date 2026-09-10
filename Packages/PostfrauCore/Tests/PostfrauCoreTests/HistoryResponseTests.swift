import Foundation
import Testing
@testable import PostfrauCore

/// What history keeps of the response, and the switch that stops it.
@Suite("History response recording")
struct HistoryResponseTests {
    private func exchange() -> HistoryRecorder.Exchange {
        let request = RequestItem(name: "R", url: "https://example.com/things")
        let built = try! RequestBuilder().build(
            request, resolver: VariableResolver(values: [:]), effectiveAuth: .none)
        let response = HTTPResponse(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: [HeaderField(name: "Content-Type", value: "application/json")],
            body: .inMemory(Data(#"{"answer":42}"#.utf8)),
            mimeType: "application/json",
            finalURL: "https://example.com/things")
        return HistoryRecorder.Exchange(
            request: request, resolvedURL: request.url, built: built,
            response: response, error: nil, startedAt: Date())
    }

    private func policy(
        level: HistoryRecordLevel = .full, storesResponseBody: Bool = true
    ) -> HistoryRecorder.Policy {
        HistoryRecorder.Policy(
            level: level, secrets: [], bodyCap: 65_536, source: .app,
            storesResponseBody: storesResponseBody)
    }

    @Test("The response body is kept by default")
    func responseIsRecorded() async throws {
        let entry = try #require(await HistoryRecorder.entry(for: exchange(), policy: policy()))
        let body = try #require(entry.responseBody)
        #expect(String(decoding: body.data, as: UTF8.self) == #"{"answer":42}"#)
        #expect(entry.requestBody != nil || entry.requestSnapshot.body == .none)
    }

    @Test("Turning it off drops the response but keeps everything else")
    func responseCanBeLeftOut() async throws {
        let entry = try #require(
            await HistoryRecorder.entry(
                for: exchange(), policy: policy(storesResponseBody: false)))
        #expect(entry.responseBody == nil, "the response body should not be stored")
        // The rest of the entry is untouched: this is not the same as dropping to a lower level.
        #expect(entry.responseHeaders?.isEmpty == false, "headers are still recorded")
        #expect(entry.statusCode == 200)
        #expect(entry.recordLevel == .full)
    }

    @Test("Below `full` there is no response body either way")
    func lowerLevelsKeepNoBodies() async throws {
        for level in [HistoryRecordLevel.metadata, .headers] {
            let entry = try #require(
                await HistoryRecorder.entry(for: exchange(), policy: policy(level: level)))
            #expect(entry.responseBody == nil)
        }
    }

    @Test("History keeps responses out of the box")
    func defaultsKeepTheResponse() {
        #expect(AppSettings().historyRecording == .full)
        #expect(AppSettings().historyStoresResponseBodies)
    }
}
