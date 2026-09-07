import Foundation
import Testing
@testable import PostfrauCore

@Suite("Collection tree")
struct CollectionTreeTests {
    @Test func walksEveryRequestWithItsFolderChain() throws {
        let collection = makeSampleCollection()
        let all = collection.allRequests()
        #expect(all.map(\.request.name).sorted() == ["Create", "Health", "List"])

        let list = try #require(all.first { $0.request.name == "List" })
        #expect(list.folderIDs.count == 2)

        let health = try #require(all.first { $0.request.name == "Health" })
        #expect(health.folderIDs.isEmpty)
    }

    @Test func countsRequestsAcrossNesting() {
        #expect(makeSampleCollection().requestCount == 3)
        #expect(RequestCollection(name: "Empty").requestCount == 0)
    }

    @Test func findsTheFolderChainToAnItem() throws {
        var collection = makeSampleCollection()
        let inner = try #require(collection.items.first?.asFolder?.items.first?.asFolder)
        let create = try #require(inner.items.last?.asRequest)

        let chain = try #require(collection.folderChain(to: create.id))
        #expect(chain.count == 2)
        #expect(chain.last == inner.id)
        #expect(collection.folderChain(to: UUID()) == nil)

        // Mutating through the tree keeps ids stable.
        var edited = create
        edited.name = "Renamed"
        let didReplace = collection.replace(.request(edited))
        #expect(didReplace)
        #expect(collection.request(withID: create.id)?.name == "Renamed")
    }

    @Test func lookupByIDFindsFoldersAndRequests() throws {
        let collection = makeSampleCollection()
        let inner = try #require(collection.items.first?.asFolder?.items.first?.asFolder)
        #expect(collection.folder(withID: inner.id)?.name == "Users")
        #expect(collection.item(withID: inner.id)?.name == "Users")
        #expect(collection.request(withID: inner.id) == nil)
        #expect(collection.item(withID: UUID()) == nil)
    }

    @Test func replaceReportsWhenTheItemIsNotThere() {
        var collection = makeSampleCollection()
        let didReplace = collection.replace(.request(RequestItem(name: "Ghost")))
        #expect(!didReplace)
    }

    @Test func removesAnItemFromAnyDepth() throws {
        var collection = makeSampleCollection()
        let inner = try #require(collection.items.first?.asFolder?.items.first?.asFolder)
        let list = try #require(inner.items.first?.asRequest)

        let removed = collection.remove(itemWithID: list.id)
        #expect(removed?.name == "List")
        #expect(collection.requestCount == 2)
        let missing = collection.remove(itemWithID: UUID())
        #expect(missing == nil)
    }

    @Test func insertsIntoTheRootAndIntoAFolder() throws {
        var collection = makeSampleCollection()
        let inner = try #require(collection.items.first?.asFolder?.items.first?.asFolder)

        let insertedAtRoot = collection.insert(.request(RequestItem(name: "Root")), into: nil, at: 0)
        #expect(insertedAtRoot)
        #expect(collection.items.first?.name == "Root")

        let insertedNested = collection.insert(.request(RequestItem(name: "Nested")), into: inner.id)
        #expect(insertedNested)
        #expect(collection.folder(withID: inner.id)?.items.last?.name == "Nested")
        #expect(collection.requestCount == 5)

        let insertedNowhere = collection.insert(.request(RequestItem(name: "Nowhere")), into: UUID())
        #expect(!insertedNowhere)
    }

    @Test func detectsIllegalDragsOfAFolderIntoItself() throws {
        let collection = makeSampleCollection()
        let outer = try #require(collection.items.first?.asFolder)
        let inner = try #require(outer.items.first?.asFolder)
        #expect(collection.folder(inner.id, isInsideOrEqualTo: outer.id))
        #expect(collection.folder(outer.id, isInsideOrEqualTo: outer.id))
        #expect(!collection.folder(outer.id, isInsideOrEqualTo: inner.id))
    }

    @Test func duplicatingGivesEveryNodeAFreshIdentity() throws {
        let original = makeSampleCollection()
        let copy = original.duplicated()

        #expect(copy.id != original.id)
        #expect(copy.name == "Acme API copy")
        #expect(copy.requestCount == original.requestCount)
        #expect(copy.revision == 1)

        let originalIDs = Set(original.allRequests().map(\.request.id))
        let copyIDs = Set(copy.allRequests().map(\.request.id))
        #expect(originalIDs.isDisjoint(with: copyIDs))
        #expect(copy.allRequests().map(\.request.name).sorted()
            == original.allRequests().map(\.request.name).sorted())
    }

    @Test func duplicatingARequestKeepsValuesButNotIdentity() {
        let original = RequestItem(
            name: "Create", method: .post, url: "/u",
            headers: [KeyValue(key: "A", value: "1")],
            body: .urlEncoded([KeyValue(key: "b", value: "2")]))
        let copy = original.duplicated()
        #expect(copy.id != original.id)
        #expect(copy.name == "Create copy")
        #expect(copy.headers.first?.id != original.headers.first?.id)
        #expect(copy.headers.first?.key == "A")
        if case .urlEncoded(let rows) = copy.body {
            #expect(rows.first?.key == "b")
            #expect(rows.first?.id != KeyValue(key: "b", value: "2").id)
        } else {
            Issue.record("body mode changed while duplicating")
        }
    }

    @Test func workspaceFindsTheCollectionThatOwnsAnItem() throws {
        let collection = makeSampleCollection()
        let other = RequestCollection(name: "Other")
        let workspace = Workspace(collections: [other, collection])
        let health = try #require(collection.allRequests().first { $0.request.name == "Health" })

        #expect(workspace.collectionContaining(itemID: health.request.id)?.id == collection.id)
        #expect(workspace.collectionContaining(itemID: other.id)?.id == other.id)
        #expect(workspace.collectionContaining(itemID: UUID()) == nil)
        #expect(workspace.totalRequestCount == 3)
    }

    @Test func workspaceResolvesTheActiveEnvironment() {
        let staging = RequestEnvironment(name: "Staging")
        let workspace = Workspace(environments: [staging], activeEnvironmentID: staging.id)
        #expect(workspace.activeEnvironment?.name == "Staging")
        #expect(Workspace(environments: [staging]).activeEnvironment == nil)
    }
}
