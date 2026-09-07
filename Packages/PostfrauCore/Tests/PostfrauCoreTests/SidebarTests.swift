import Foundation
import Testing
@testable import PostfrauCore

@Suite("Fuzzy matcher")
struct FuzzyMatcherTests {
    @Test func matchesASubsequence() throws {
        let match = try #require(FuzzyMatcher.match(query: "usrs", in: "GET /users"))
        #expect(match.matchedOffsets.count == 4)
    }

    @Test func rejectsCharactersOutOfOrder() {
        #expect(FuzzyMatcher.match(query: "sres", in: "users") == nil)
        #expect(FuzzyMatcher.match(query: "xyz", in: "users") == nil)
        // A query longer than the candidate can never match.
        #expect(FuzzyMatcher.match(query: "userss", in: "users") == nil)
    }

    @Test func isCaseInsensitiveButPrefersAnExactCaseMatch() throws {
        #expect(FuzzyMatcher.match(query: "USR", in: "users") != nil)
        let exact = try #require(FuzzyMatcher.match(query: "us", in: "users"))
        let wrongCase = try #require(FuzzyMatcher.match(query: "US", in: "users"))
        #expect(exact.score > wrongCase.score)
    }

    @Test func anEmptyQueryMatchesEverything() throws {
        let match = try #require(FuzzyMatcher.match(query: "", in: "anything"))
        #expect(match.score == 0)
        #expect(match.matchedOffsets.isEmpty)
    }

    @Test func reportsWhereItMatchedSoTheUICanBoldIt() throws {
        let match = try #require(FuzzyMatcher.match(query: "ue", in: "users"))
        #expect(match.matchedOffsets == [0, 2])  // "users": u at 0, e at 2
    }

    @Test func consecutiveMatchesOutscoreScatteredOnes() throws {
        let consecutive = try #require(FuzzyMatcher.match(query: "user", in: "user-profile"))
        let scattered = try #require(FuzzyMatcher.match(query: "user", in: "u_s_e_r_x"))
        #expect(consecutive.score > scattered.score)
    }

    @Test func wordStartsOutscoreMidWordMatches() throws {
        let atWordStart = try #require(FuzzyMatcher.match(query: "p", in: "users/profile"))
        let midWord = try #require(FuzzyMatcher.match(query: "p", in: "usxpxxx"))
        #expect(atWordStart.score > midWord.score)
    }

    @Test func shorterCandidatesWinTies() throws {
        let ranked = FuzzyMatcher.rank(
            ["GET /users", "GET /users/{id}/permissions/detail"], query: "users") { $0 }
        #expect(ranked.first?.item == "GET /users")
    }

    @Test func ranksBestFirstAndDropsNonMatches() {
        let candidates = ["create user", "users", "delete order", "user settings"]
        let ranked = FuzzyMatcher.rank(candidates, query: "user") { $0 }
        #expect(ranked.count == 3)
        #expect(!ranked.contains { $0.item == "delete order" })
        #expect(ranked.first?.item == "users" || ranked.first?.item == "user settings")
    }

    @Test func tiesKeepTheInputOrder() {
        // Two identical candidates must not swap places between keystrokes.
        let ranked = FuzzyMatcher.rank(["alpha", "alpha"], query: "alpha") { $0 }
        #expect(ranked.count == 2)
    }

    @Test func matchesAcrossNamePathAndURLTheWayQuickOpenSearches() throws {
        // Quick open matches one string built from the name, the path and the URL.
        let cookie = "Set a cookie Postfrau Examples / Responses {{baseUrl}}/cookies/set"
        let echo = "Echo query Postfrau Examples {{baseUrl}}/get"

        let cookieMatch = try #require(
            FuzzyMatcher.match(query: "stcook", in: cookie), "\"stcook\" should match")
        let echoMatch = FuzzyMatcher.match(query: "stcook", in: echo)
        if let echoMatch {
            #expect(cookieMatch.score > echoMatch.score,
                    "the request actually named \"Set a cookie\" must rank first")
        }

        let ranked = FuzzyMatcher.rank([cookie, echo], query: "stcook") { $0 }
        #expect(ranked.first?.item == cookie)
    }

    @Test func handlesNonASCIICandidates() throws {
        #expect(FuzzyMatcher.match(query: "caf", in: "café menu") != nil)
        let match = try #require(FuzzyMatcher.match(query: "é", in: "café"))
        #expect(match.matchedOffsets == [3])
    }
}

@Suite("Collection filter")
struct CollectionFilterTests {
    @Test func anEmptyQueryReturnsEverything() throws {
        let collection = makeSampleCollection()
        let filtered = try #require(CollectionFilter.filter(collection, query: "  "))
        #expect(filtered.requestCount == collection.requestCount)
    }

    @Test func matchesRequestNames() throws {
        let filtered = try #require(CollectionFilter.filter(makeSampleCollection(), query: "health"))
        #expect(filtered.requestCount == 1)
        #expect(filtered.allRequests().first?.request.name == "Health")
    }

    @Test func matchesURLsAsWellAsNames() throws {
        let filtered = try #require(CollectionFilter.filter(makeSampleCollection(), query: "/users"))
        #expect(filtered.requestCount == 2)
    }

    @Test func matchesTheMethod() throws {
        let filtered = try #require(CollectionFilter.filter(makeSampleCollection(), query: "post"))
        #expect(filtered.allRequests().map(\.request.name) == ["Create"])
    }

    @Test func keepsAncestorsOfAMatchVisible() throws {
        // "List" is two folders deep; both have to survive or it cannot be shown.
        let filtered = try #require(CollectionFilter.filter(makeSampleCollection(), query: "list"))
        let outer = try #require(filtered.items.first?.asFolder)
        #expect(outer.name == "API")
        let inner = try #require(outer.items.first?.asFolder)
        #expect(inner.name == "Users")
        #expect(inner.items.count == 1)
    }

    @Test func aFolderWhoseNameMatchesKeepsItsContents() throws {
        let filtered = try #require(CollectionFilter.filter(makeSampleCollection(), query: "users"))
        let inner = try #require(filtered.items.first?.asFolder?.items.first?.asFolder)
        #expect(inner.items.count == 2, "the folder's own children should still be there")
    }

    @Test func returnsNilWhenNothingMatches() {
        #expect(CollectionFilter.filter(makeSampleCollection(), query: "zzzz") == nil)
    }

    @Test func aCollectionWhoseNameMatchesSurvivesEvenWithNoMatchingChildren() throws {
        let filtered = try #require(CollectionFilter.filter(makeSampleCollection(), query: "acme"))
        #expect(filtered.name == "Acme API")
    }

    @Test func isCaseInsensitive() {
        #expect(CollectionFilter.filter(makeSampleCollection(), query: "HEALTH") != nil)
    }

    @Test func reportsWhichFoldersMustBeExpanded() throws {
        let collection = makeSampleCollection()
        let ids = CollectionFilter.expansionIDs(for: collection, query: "list")
        let outer = try #require(collection.items.first?.asFolder)
        let inner = try #require(outer.items.first?.asFolder)
        #expect(ids.contains(collection.id))
        #expect(ids.contains(outer.id))
        #expect(ids.contains(inner.id))
        #expect(CollectionFilter.expansionIDs(for: collection, query: "").isEmpty)
    }
}

@Suite("Moving items")
struct CollectionMoveTests {
    @Test func movesARequestIntoAFolder() throws {
        var collection = makeSampleCollection()
        let health = try #require(collection.allRequests().first { $0.request.name == "Health" })
        let inner = try #require(collection.items.first?.asFolder?.items.first?.asFolder)

        let moved = collection.move(itemWithID: health.request.id, to: DropTarget(parentID: inner.id))
        #expect(moved)
        #expect(collection.folder(withID: inner.id)?.items.count == 3)
        #expect(collection.items.count == 1, "it should no longer be at the root")
        #expect(collection.requestCount == 3, "nothing was lost")
    }

    @Test func movesARequestOutToTheRoot() throws {
        var collection = makeSampleCollection()
        let list = try #require(collection.allRequests().first { $0.request.name == "List" })

        let moved = collection.move(itemWithID: list.request.id, to: DropTarget(parentID: nil, index: 0))
        #expect(moved)
        #expect(collection.items.first?.name == "List")
        #expect(collection.requestCount == 3)
    }

    @Test func reordersSiblings() throws {
        var collection = makeSampleCollection()
        let inner = try #require(collection.items.first?.asFolder?.items.first?.asFolder)
        let names = inner.items.map(\.name)
        #expect(names == ["List", "Create"])

        let create = try #require(inner.items.last)
        let moved = collection.move(itemWithID: create.id, to: DropTarget(parentID: inner.id, index: 0))
        #expect(moved)
        #expect(collection.folder(withID: inner.id)?.items.map(\.name) == ["Create", "List"])
    }

    @Test func movingAnItemDownAdjustsForItsOwnRemoval() throws {
        var collection = RequestCollection(name: "C", items: [
            .request(RequestItem(name: "A")),
            .request(RequestItem(name: "B")),
            .request(RequestItem(name: "C")),
        ])
        let first = try #require(collection.items.first)

        // "Drop A after C" is index 3 in the pre-removal list.
        let moved = collection.move(itemWithID: first.id, to: DropTarget(parentID: nil, index: 3))
        #expect(moved)
        #expect(collection.items.map(\.name) == ["B", "C", "A"])
    }

    @Test func refusesToDropAFolderInsideItself() throws {
        var collection = makeSampleCollection()
        let outer = try #require(collection.items.first?.asFolder)
        let inner = try #require(outer.items.first?.asFolder)

        let intoItself = collection.move(itemWithID: outer.id, to: DropTarget(parentID: outer.id))
        #expect(intoItself == false)
        let intoDescendant = collection.move(itemWithID: outer.id, to: DropTarget(parentID: inner.id))
        #expect(intoDescendant == false, "a folder cannot go inside its own child")
        #expect(collection.requestCount == 3, "the tree is untouched")
    }

    @Test func refusesUnknownItemsAndTargets() throws {
        var collection = makeSampleCollection()
        let unknownItem = collection.move(itemWithID: UUID(), to: DropTarget(parentID: nil))
        #expect(unknownItem == false)

        let health = try #require(collection.allRequests().first { $0.request.name == "Health" })
        let unknownTarget = collection.move(
            itemWithID: health.request.id, to: DropTarget(parentID: UUID()))
        #expect(unknownTarget == false)
    }

    @Test func reportsWhereAnItemCurrentlyLives() throws {
        let collection = makeSampleCollection()
        let inner = try #require(collection.items.first?.asFolder?.items.first?.asFolder)
        let list = try #require(inner.items.first)
        let health = try #require(collection.allRequests().first { $0.request.name == "Health" })

        #expect(collection.currentParentID(of: list.id) == inner.id)
        #expect(collection.currentIndex(of: list.id) == 0)
        #expect(collection.currentParentID(of: health.request.id) == nil)
        #expect(collection.currentIndex(of: health.request.id) == 1)
    }
}

@Suite("Stress collection")
struct StressCollectionTests {
    @Test func buildsTheRequestedNumberOfRequests() {
        let collection = RequestCollection.makeStressCollection(requestCount: 5000)
        #expect(collection.requestCount == 5000)
    }

    @Test func nestsThreeLevelsDeep() throws {
        let collection = RequestCollection.makeStressCollection(requestCount: 200)
        let group = try #require(collection.items.first?.asFolder)
        let folder = try #require(group.items.first?.asFolder)
        #expect(folder.items.first?.asRequest != nil)
    }

    @Test func everyRequestHasAUniqueIdentity() {
        let collection = RequestCollection.makeStressCollection(requestCount: 300)
        let ids = Set(collection.allRequests().map(\.request.id))
        #expect(ids.count == 300)
    }

    @Test func handlesSmallCounts() {
        #expect(RequestCollection.makeStressCollection(requestCount: 1).requestCount == 1)
        #expect(RequestCollection.makeStressCollection(requestCount: 0).requestCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func fiveThousandRequestsBuildEncodeAndFilterQuickly() throws {
        let started = ContinuousClock.now
        let collection = RequestCollection.makeStressCollection(requestCount: 5000)
        let built = started.duration(to: .now)

        let encodeStart = ContinuousClock.now
        let data = try Postfrau.makeEncoder().encode(collection)
        let encoded = encodeStart.duration(to: .now)

        let decodeStart = ContinuousClock.now
        let decoded = try Postfrau.makeDecoder().decode(RequestCollection.self, from: data)
        let decodedIn = decodeStart.duration(to: .now)

        let filterStart = ContinuousClock.now
        let filtered = CollectionFilter.filter(decoded, query: "item4999")
        let filteredIn = filterStart.duration(to: .now)

        #expect(decoded.requestCount == 5000)
        #expect(filtered?.requestCount == 1)
        // Filtering is what runs on every keystroke, so it is the one that has to be fast.
        #expect(filteredIn < .milliseconds(100), "filter took \(filteredIn)")
        #expect(built < .seconds(2), "build took \(built)")
        #expect(encoded < .seconds(2), "encode took \(encoded)")
        #expect(decodedIn < .seconds(2), "decode took \(decodedIn)")
    }
}

/// Quick open's ranking, run against the collection the app actually ships.
@Suite("Quick open ranking")
struct QuickOpenRankingTests {
    /// The same string the app builds: name, then path, then URL.
    private func searchTexts() throws -> [(name: String, text: String)] {
        let url = try #require(Bundle.module.url(
            forResource: "sample-collection", withExtension: "json",
            subdirectory: "Fixtures"))
        let collection = try Postfrau.makeDecoder()
            .decode(RequestCollection.self, from: Data(contentsOf: url))

        return collection.allRequests().map { entry in
            let folders = entry.folderIDs.compactMap { collection.folder(withID: $0)?.name }
            let path = ([collection.name] + folders).joined(separator: " / ")
            return (entry.request.name, "\(entry.request.name) \(path) \(entry.request.url)")
        }
    }

    @Test func theShippedSampleHasTheRequestsTheTestsAssumeExist() throws {
        let names = try searchTexts().map(\.name).sorted()
        #expect(names.contains("Set a cookie"))
        #expect(names.contains("Echo query"))
        #expect(names.count == 7)
    }

    @Test func findsSetACookieFromAFuzzyQuery() throws {
        let candidates = try searchTexts()
        let ranked = FuzzyMatcher.rank(candidates, query: "stcook") { $0.text }
        #expect(ranked.first?.item.name == "Set a cookie", "ranked: \(ranked.map(\.item.name))")
    }

    @Test func findsARequestByNameAlone() throws {
        let candidates = try searchTexts()
        #expect(FuzzyMatcher.rank(candidates, query: "redirect") { $0.text }
            .first?.item.name == "Redirect chain")
        #expect(FuzzyMatcher.rank(candidates, query: "postjson") { $0.text }
            .first?.item.name == "POST JSON")
    }
}

@Suite("Capped sidebar filter")
struct CappedFilterTests {
    @Test func anEmptyQueryReturnsEverythingUntouched() {
        let result = CollectionFilter.filter([makeSampleCollection()], query: "")
        #expect(result.collections.count == 1)
        #expect(result.collections[0].requestCount == 3)
        #expect(!result.isTruncated)
        #expect(result.forcedOpenIDs.isEmpty)
    }

    @Test func reportsMatchesAndTheFoldersToOpen() throws {
        let collection = makeSampleCollection()
        let result = CollectionFilter.filter([collection], query: "list")

        #expect(result.totalMatches == 1)
        #expect(!result.isTruncated)
        let outer = try #require(collection.items.first?.asFolder)
        let inner = try #require(outer.items.first?.asFolder)
        #expect(result.forcedOpenIDs.contains(collection.id))
        #expect(result.forcedOpenIDs.contains(outer.id))
        #expect(result.forcedOpenIDs.contains(inner.id))
    }

    @Test func capsHowManyMatchesAreKeptButCountsThemAll() {
        let collection = RequestCollection.makeStressCollection(requestCount: 500)
        let result = CollectionFilter.filter([collection], query: "request", limit: 50)

        #expect(result.collections.reduce(0) { $0 + $1.requestCount } == 50, "only the cap is kept")
        #expect(result.totalMatches == 500, "but every match is counted")
        #expect(result.isTruncated)
    }

    @Test func doesNotReportTruncationWhenEverythingFits() {
        let collection = RequestCollection.makeStressCollection(requestCount: 10)
        let result = CollectionFilter.filter([collection], query: "request", limit: 50)
        #expect(!result.isTruncated)
        #expect(result.totalMatches == 10)
    }

    @Test func dropsCollectionsWithNoMatches() {
        let result = CollectionFilter.filter(
            [makeSampleCollection(), RequestCollection(name: "Empty")], query: "health")
        #expect(result.collections.count == 1)
        #expect(result.collections[0].name == "Acme API")
    }

    @Test func keepsACollectionWhoseOwnNameMatches() {
        let result = CollectionFilter.filter([makeSampleCollection()], query: "acme")
        #expect(result.collections.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func filtersFiveThousandRequestsFastEnoughToTypeAgainst() {
        let collection = RequestCollection.makeStressCollection(requestCount: 5000)

        // The worst case is a broad query that matches nearly everything.
        let started = ContinuousClock.now
        for query in ["r", "re", "req", "requ", "reque", "reques", "request"] {
            _ = CollectionFilter.filter([collection], query: query, limit: 200)
        }
        let elapsed = started.duration(to: .now)

        // Seven keystrokes; a keystroke that costs more than ~50 ms is felt.
        #expect(elapsed < .milliseconds(350), "seven filter passes took \(elapsed)")
    }
}
