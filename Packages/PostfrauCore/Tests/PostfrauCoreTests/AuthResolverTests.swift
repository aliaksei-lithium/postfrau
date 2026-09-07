import Foundation
import Testing
@testable import PostfrauCore

@Suite("Auth resolver")
struct AuthResolverTests {
    @Test func requestAuthWinsOverEverything() {
        let effective = AuthResolver.effective(
            requestAuth: .bearer(token: "r"),
            folderChain: [Folder(name: "F", auth: .bearer(token: "f"))],
            collection: RequestCollection(name: "C", auth: .bearer(token: "c")))
        #expect(effective.auth == .bearer(token: "r"))
        #expect(effective.source == .request)
        #expect(!effective.isInherited)
    }

    @Test func inheritWalksToTheInnermostFolderThatDefinesAuth() {
        let outer = Folder(name: "Outer", auth: .bearer(token: "outer"))
        let inner = Folder(name: "Inner", auth: .bearer(token: "inner"))
        let effective = AuthResolver.effective(
            requestAuth: .inherit, folderChain: [outer, inner],
            collection: RequestCollection(name: "C", auth: .bearer(token: "c")))
        #expect(effective.auth == .bearer(token: "inner"))
        #expect(effective.source == .folder(name: "Inner"))
        #expect(effective.isInherited)
    }

    @Test func inheritSkipsFoldersThatAlsoInherit() {
        let outer = Folder(name: "Outer", auth: .bearer(token: "outer"))
        let inner = Folder(name: "Inner", auth: .inherit)
        let effective = AuthResolver.effective(
            requestAuth: .inherit, folderChain: [outer, inner], collection: nil)
        #expect(effective.source == .folder(name: "Outer"))
    }

    @Test func inheritFallsThroughToTheCollection() {
        let effective = AuthResolver.effective(
            requestAuth: .inherit,
            folderChain: [Folder(name: "F", auth: .inherit)],
            collection: RequestCollection(name: "Acme", auth: .bearer(token: "c")))
        #expect(effective.auth == .bearer(token: "c"))
        #expect(effective.source == .collection(name: "Acme"))
    }

    @Test func aCollectionWithNoAuthMeansNothingIsSent() {
        let effective = AuthResolver.effective(
            requestAuth: .inherit, folderChain: [],
            collection: RequestCollection(name: "Acme", auth: .none))
        #expect(effective.auth == .none)
        #expect(effective.source == .none)
        #expect(!effective.isInherited)
    }

    @Test func explicitNoneOnTheRequestOverridesInheritedAuth() {
        let effective = AuthResolver.effective(
            requestAuth: .none, folderChain: [Folder(name: "F", auth: .bearer(token: "f"))],
            collection: nil)
        #expect(effective.auth == .none)
        #expect(effective.source == .request)
    }

    @Test func resolvesThroughTheRealTreeGivenARequestID() throws {
        let collection = makeSampleCollection()
        let list = try #require(collection.allRequests().first { $0.request.name == "List" }?.request)
        let effective = AuthResolver.effective(for: list, in: collection)
        #expect(effective.source == .folder(name: "Users"))
        #expect(effective.auth == .bearer(token: "{{folderToken}}"))

        let health = try #require(collection.allRequests().first { $0.request.name == "Health" }?.request)
        #expect(AuthResolver.effective(for: health, in: collection).source
            == .collection(name: "Acme API"))
    }

    @Test func basicAuthBecomesABase64Header() throws {
        let resolver = VariableResolver(values: ["u": "ada", "p": "s3cret"])
        let wire = try #require(AuthResolver.wireValue(
            for: .basic(username: "{{u}}", password: "{{p}}"), resolver: resolver))
        #expect(wire == .header(name: "Authorization", value: "Basic YWRhOnMzY3JldA=="))
    }

    @Test func bearerAuthBecomesAnAuthorizationHeader() throws {
        let resolver = VariableResolver(values: ["t": "abc"])
        let wire = try #require(AuthResolver.wireValue(for: .bearer(token: "{{t}}"), resolver: resolver))
        #expect(wire == .header(name: "Authorization", value: "Bearer abc"))
    }

    @Test func apiKeyGoesInTheHeaderOrTheQueryAsConfigured() throws {
        let resolver = VariableResolver(values: ["k": "secret"])
        let header = try #require(AuthResolver.wireValue(
            for: .apiKey(key: "X-Key", value: "{{k}}", location: .header), resolver: resolver))
        #expect(header == .header(name: "X-Key", value: "secret"))

        let query = try #require(AuthResolver.wireValue(
            for: .apiKey(key: "api_key", value: "{{k}}", location: .query), resolver: resolver))
        #expect(query == .query(name: "api_key", value: "secret"))
    }

    @Test func emptyOrAbsentAuthPutsNothingOnTheWire() {
        let resolver = VariableResolver(values: [:])
        #expect(AuthResolver.wireValue(for: .none, resolver: resolver) == nil)
        #expect(AuthResolver.wireValue(for: .inherit, resolver: resolver) == nil)
        #expect(AuthResolver.wireValue(for: .bearer(token: ""), resolver: resolver) == nil)
        #expect(AuthResolver.wireValue(
            for: .basic(username: "", password: ""), resolver: resolver) == nil)
        #expect(AuthResolver.wireValue(
            for: .apiKey(key: "", value: "v", location: .header), resolver: resolver) == nil)
    }

    @Test func basicAuthWithOnlyAPasswordStillSends() throws {
        let wire = try #require(AuthResolver.wireValue(
            for: .basic(username: "", password: "p"), resolver: VariableResolver(values: [:])))
        #expect(wire.value == "Basic \(Data(":p".utf8).base64EncodedString())")
    }
}
