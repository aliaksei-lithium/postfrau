import Foundation
import Testing
@testable import PostfrauCore

@Suite("Name paths")
struct NamePathTests {
    @Test func splitsOnSlashes() {
        #expect(NamePath("Acme API/Users/List").components == ["Acme API", "Users", "List"])
        #expect(NamePath("Acme API").components == ["Acme API"])
        #expect(NamePath("").components.isEmpty)
    }

    @Test func anEscapedSlashIsPartOfTheName() {
        // A request called "GET /users" has to stay addressable.
        #expect(NamePath(#"Acme\/Beta/Users"#).components == ["Acme/Beta", "Users"])
        #expect(NamePath(#"API/GET \/users"#).components == ["API", "GET /users"])
    }

    @Test func roundTripsThroughItsOwnDescription() {
        for components in [["Acme API", "Users"], ["A/B", "C\\D"], ["one"]] {
            let path = NamePath(components: components)
            #expect(NamePath(path.description).components == components)
        }
    }

    @Test func emptyComponentsAreDropped() {
        #expect(NamePath("//Acme//Users//").components == ["Acme", "Users"])
    }

    @Test func matchingIgnoresCase() {
        #expect(NamePath.matches("Users", "users"))
        #expect(NamePath.matches("ACME API", "acme api"))
        #expect(!NamePath.matches("Users", "user"))
    }
}

@Suite("Item resolution")
struct ItemResolverTests {
    private func workspace() -> Workspace {
        Workspace(collections: [makeSampleCollection()])
    }

    @Test func findsACollectionAFolderAndARequest() throws {
        let workspace = workspace()
        #expect(try ItemResolver.resolve("Acme API", in: workspace).kind == "collection")
        #expect(try ItemResolver.resolve("Acme API/API/Users", in: workspace).kind == "folder")
        #expect(try ItemResolver.resolve("Acme API/API/Users/List", in: workspace).kind == "request")
        #expect(try ItemResolver.resolve("Acme API/Health", in: workspace).kind == "request")
    }

    @Test func caseDoesNotMatter() throws {
        let resolved = try ItemResolver.resolve("acme api/api/users/list", in: workspace())
        #expect(resolved.name == "List")
    }

    @Test func aUuidWorksToo() throws {
        let workspace = workspace()
        let id = try #require(workspace.collections[0].allRequests().first?.request.id)
        #expect(try ItemResolver.resolve(id.uuidString, in: workspace).id == id)
    }

    @Test func saysWhenSomethingIsNotThere() {
        #expect(throws: ItemResolver.ResolveError.self) {
            try ItemResolver.resolve("Acme API/Nope", in: workspace())
        }
        #expect(throws: ItemResolver.ResolveError.self) {
            try ItemResolver.resolve("Acme API/API/Users/List/Deeper", in: workspace())
        }
    }

    @Test func complainsWhenTwoThingsShareAName() throws {
        var collection = RequestCollection(name: "C")
        collection.items = [
            .request(RequestItem(name: "Same")),
            .request(RequestItem(name: "same")),
        ]
        let workspace = Workspace(collections: [collection])

        // Ambiguity is reported rather than silently picking one.
        #expect(throws: ItemResolver.ResolveError.self) {
            try ItemResolver.resolve("C/Same", in: workspace)
        }
    }

    @Test func buildsThePathBackFromAnID() throws {
        let workspace = workspace()
        let request = try #require(
            workspace.collections[0].allRequests().map(\.request).first { $0.name == "List" })
        let path = try #require(ItemResolver.path(toItemWithID: request.id, in: workspace))
        #expect(path.description == "Acme API/API/Users/List")
        // And the path it produced resolves back to the same item.
        #expect(try ItemResolver.resolve(path.description, in: workspace).id == request.id)
    }
}

@Suite("JSON path")
struct JSONPathTests {
    private func value(_ json: String) throws -> JSONValue {
        try Postfrau.makeDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func readsNestedKeysAndIndexes() throws {
        let root = try value(#"{"data":{"items":[{"name":"Ada"},{"name":"Grace"}]},"ok":true}"#)
        #expect(JSONPath.evaluate("$.data.items[0].name", on: root) == "Ada")
        #expect(JSONPath.evaluate("$.data.items[1].name", on: root) == "Grace")
        #expect(JSONPath.evaluate("$.ok", on: root) == "true")
        #expect(JSONPath.evaluate("data.items[0].name", on: root) == "Ada", "the $ is optional")
    }

    @Test func aNegativeIndexCountsFromTheEnd() throws {
        let root = try value(#"{"a":[1,2,3]}"#)
        #expect(JSONPath.evaluate("$.a[-1]", on: root) == "3")
    }

    @Test func numbersKeepTheirPrecision() throws {
        // An id past the range a Double represents exactly must not come back rounded: this one
        // is 2^53 + 1, which as a Double is 9007199254740992.
        let root = try value(#"{"id":9007199254740993,"price":19.90,"big":1e30}"#)
        #expect(JSONPath.evaluate("$.id", on: root) == "9007199254740993")
        #expect(JSONPath.evaluate("$.big", on: root) == "1000000000000000000000000000000")
        // The value is kept, not the spelling: a trailing zero is not part of the number.
        #expect(JSONPath.evaluate("$.price", on: root) == "19.9")
    }

    @Test func bracketNotationAddressesAwkwardKeys() throws {
        let root = try value(#"{"a.b":{"c":"x"},"with space":"y"}"#)
        #expect(JSONPath.evaluate("$['a.b'].c", on: root) == "x")
        #expect(JSONPath.evaluate(#"$["with space"]"#, on: root) == "y")
    }

    @Test func anObjectComesBackAsJSON() throws {
        let root = try value(#"{"a":{"b":1}}"#)
        #expect(JSONPath.evaluate("$.a", on: root) == #"{"b":1}"#)
        #expect(JSONPath.evaluate("$", on: root) == #"{"a":{"b":1}}"#)
    }

    @Test func aPathThatMatchesNothingSaysSo() throws {
        let root = try value(#"{"a":[1]}"#)
        #expect(JSONPath.evaluate("$.b", on: root) == nil)
        #expect(JSONPath.evaluate("$.a[9]", on: root) == nil)
        #expect(JSONPath.evaluate("$.a.b", on: root) == nil, "indexing an array by key")
    }

    @Test func rejectsWhatItDoesNotImplement() {
        #expect(JSONPath.parse("$.a[") == nil, "an unclosed bracket")
        #expect(JSONPath.parse("$.a[*]") == nil, "wildcards are not supported")
        #expect(JSONPath.parse("") == nil)
        #expect(JSONPath.parse("$") == [])
    }
}
