import Foundation
import Testing

@testable import PostfrauCore

@Suite("Local API")
struct LocalAPITests {
    @Test func aTokenIsLongRandomAndURLSafe() {
        let first = LocalAPI.makeToken(), second = LocalAPI.makeToken()
        #expect(first != second)
        // 32 bytes, base64 without padding.
        #expect(first.count == 43)
        // It ends up in a shell export and a URL header, so none of `+ / =` may appear.
        #expect(first.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func tokensMatchOnlyWhenTheyAreEqual() {
        let token = LocalAPI.makeToken()
        #expect(LocalAPI.tokensMatch(token, token))
        #expect(!LocalAPI.tokensMatch(token, token + "x"))
        #expect(!LocalAPI.tokensMatch(token, String(token.dropLast())))
        #expect(!LocalAPI.tokensMatch(token, String(repeating: "a", count: token.count)))
    }

    /// An empty configured token would otherwise match an empty `Authorization` header, which is
    /// what a request with no credentials at all looks like.
    @Test func anEmptyTokenNeverMatches() {
        #expect(!LocalAPI.tokensMatch("", ""))
        #expect(!LocalAPI.tokensMatch("", "anything"))
        #expect(!LocalAPI.tokensMatch("anything", ""))
    }

    @Test func theWireTypesSurviveARoundTrip() throws {
        let run = LocalAPI.RunBody(
            path: "API/Users/List", environment: "staging",
            variables: ["page": "2"], captures: ["token": "$.data.token"], bodyCap: 1024)
        let decodedRun = try JSONDecoder().decode(
            LocalAPI.RunBody.self, from: JSONEncoder().encode(run))
        #expect(decodedRun.path == run.path)
        #expect(decodedRun.environment == "staging")
        #expect(decodedRun.variables == run.variables)
        #expect(decodedRun.captures == run.captures)
        #expect(decodedRun.bodyCap == 1024)

        let send = LocalAPI.SendBody(
            method: "POST", url: "https://example.test/v2/recovery",
            headers: [HeaderField(name: "Authorization", value: "Bearer x")],
            body: #"{"force":true}"#)
        let decodedSend = try JSONDecoder().decode(
            LocalAPI.SendBody.self, from: JSONEncoder().encode(send))
        #expect(decodedSend.method == "POST")
        #expect(decodedSend.headers?.first?.name == "Authorization")
        #expect(decodedSend.body == #"{"force":true}"#)
    }

    @Test func aPatchCrossesTheWire() throws {
        let run = LocalAPI.RunBody(
            path: "Payments/Create",
            patch: RequestPatch(
                body: "{}", fields: [.init(path: "partner_bank_id", value: "7")],
                headers: [HeaderField(name: "X-Correlation-ID", value: "abc")]))
        let decoded = try JSONDecoder().decode(
            LocalAPI.RunBody.self, from: JSONEncoder().encode(run))
        #expect(decoded.patch == run.patch)

        // A tool that predates the field sends none, and the app reads that as no patch.
        let old = try JSONDecoder().decode(
            LocalAPI.RunBody.self, from: Data(#"{"path":"a"}"#.utf8))
        #expect(old.patch == nil)
    }

    /// The tool refuses to send a patch to an app that cannot read one, so an app that says
    /// nothing about capabilities has to decode as having none.
    @Test func anOldAppReportsNoCapabilities() throws {
        let old = try JSONDecoder().decode(
            LocalAPI.Ping.self, from: Data(#"{"version":"3.4","dataFolder":"/x"}"#.utf8))
        #expect(old.capabilities == nil)
        #expect(LocalAPI.Ping(version: "3.5", dataFolder: "/x").capabilities?
            .contains(LocalAPI.Capability.requestPatch) == true)
    }

    /// The default is off with no token, so a workspace that never asks for this never stores a
    /// credential, and an upgrade cannot silently open a socket.
    @Test func theAPIIsOffAndTokenlessByDefault() throws {
        let settings = AppSettings()
        #expect(!settings.localAPIEnabled)
        #expect(settings.localAPIToken.isEmpty)
        #expect(settings.localAPIPort == LocalAPI.defaultPort)

        let old = Data(#"{"schemaVersion":1,"editorFontSize":12}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(!decoded.localAPIEnabled)
        #expect(decoded.localAPIToken.isEmpty)
    }
}
