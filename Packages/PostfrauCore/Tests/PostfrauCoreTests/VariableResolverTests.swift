import Foundation
import Testing
@testable import PostfrauCore

@Suite("Variable resolver")
struct VariableResolverTests {
    private func resolver(
        _ layers: [(VariableSource, [String: String])],
        dynamics: [String: String] = [:]
    ) -> VariableResolver {
        VariableResolver(
            scope: .test(layers),
            dynamics: FixedDynamicVariables(values: dynamics))
    }

    @Test func substitutesASingleVariable() {
        let result = resolver([(.globals, ["host": "example.com"])])
            .resolve("https://{{host}}/users")
        #expect(result.text == "https://example.com/users")
        #expect(result.isFullyResolved)
    }

    @Test func leavesTextWithoutVariablesUntouched() {
        let result = resolver([]).resolve("https://example.com/users?a=1")
        #expect(result.text == "https://example.com/users?a=1")
        #expect(result.isFullyResolved)
    }

    @Test func environmentBeatsFolderBeatsCollectionBeatsGlobals() {
        let scope: [(VariableSource, [String: String])] = [
            (.environment(name: "Staging"), ["v": "env"]),
            (.folder(name: "Inner"), ["v": "folder", "w": "folderW"]),
            (.collection(name: "C"), ["v": "collection", "w": "collectionW", "x": "collectionX"]),
            (.globals, ["v": "globals", "w": "globalsW", "x": "globalsX", "y": "globalsY"]),
        ]
        let result = resolver(scope).resolve("{{v}}/{{w}}/{{x}}/{{y}}")
        #expect(result.text == "env/folderW/collectionX/globalsY")
    }

    @Test func innermostFolderWinsOverOuterFolder() {
        let collection = RequestCollection(
            name: "C", variables: [Variable(key: "v", value: "collection")])
        let outer = Folder(name: "Outer", variables: [Variable(key: "v", value: "outer")])
        let inner = Folder(name: "Inner", variables: [Variable(key: "v", value: "inner")])
        let scope = VariableScope.build(
            environment: nil, collection: collection,
            folderChain: [outer, inner], globals: Globals())
        #expect(VariableResolver(scope: scope).resolved("{{v}}") == "inner")
    }

    @Test func resolvesNestedReferences() {
        let result = resolver([(.globals, [
            "url": "{{scheme}}://{{host}}",
            "scheme": "https",
            "host": "{{sub}}.example.com",
            "sub": "api",
        ])]).resolve("{{url}}/v1")
        #expect(result.text == "https://api.example.com/v1")
        #expect(result.isFullyResolved)
    }

    @Test func reportsUnresolvedNamesAndLeavesThemLiteral() {
        let result = resolver([(.globals, ["a": "1"])]).resolve("{{a}}-{{b}}-{{c}}-{{b}}")
        #expect(result.text == "1-{{b}}-{{c}}-{{b}}")
        #expect(result.unresolved == ["b", "c"])
    }

    @Test func detectsADirectCycle() {
        let result = resolver([(.globals, ["a": "{{a}}"])]).resolve("x{{a}}y")
        #expect(result.cycles == ["a"])
        #expect(result.text == "x{{a}}y")
        #expect(!result.isFullyResolved)
    }

    @Test func detectsAnIndirectCycle() {
        let result = resolver([(.globals, ["a": "{{b}}", "b": "{{c}}", "c": "{{a}}"])])
            .resolve("{{a}}")
        #expect(!result.cycles.isEmpty)
        #expect(result.text.contains("{{a}}"))
    }

    @Test func stopsAtTheDepthLimit() {
        // v0 → v1 → … → v20: deeper than VariableResolver.maxDepth.
        var values: [String: String] = [:]
        for level in 0..<20 { values["v\(level)"] = "{{v\(level + 1)}}" }
        values["v20"] = "bottom"
        let result = resolver([(.globals, values)]).resolve("{{v0}}")
        #expect(!result.cycles.isEmpty)
        #expect(result.text != "bottom")
    }

    @Test func trimsWhitespaceInsideBraces() {
        let result = resolver([(.globals, ["host": "example.com"])])
            .resolve("{{ host }} {{\thost\t}}")
        #expect(result.text == "example.com example.com")
    }

    @Test func escapedBracesAreNotSubstituted() {
        let result = resolver([(.globals, ["a": "1"])]).resolve(#"literal \{{a}} and {{a}}"#)
        #expect(result.text == "literal {{a}} and 1")
        #expect(result.unresolved.isEmpty)
    }

    @Test func unterminatedBracesAreLeftAlone() {
        let result = resolver([(.globals, ["a": "1"])]).resolve("{{a}} then {{oops")
        #expect(result.text == "1 then {{oops")
    }

    @Test func emptyBracesAreLeftAlone() {
        #expect(resolver([]).resolved("{{}}") == "{{}}")
    }

    @Test func dynamicVariablesAreNotShadowedByUserVariables() {
        // A user variable literally named "$guid" must not win over the dynamic provider.
        let result = resolver(
            [(.globals, ["$guid": "user-value"])],
            dynamics: ["guid": "dynamic-value"]
        ).resolve("{{$guid}}")
        #expect(result.text == "dynamic-value")
    }

    @Test func unknownDynamicVariableIsReportedAsUnresolved() {
        let result = resolver([], dynamics: ["guid": "g"]).resolve("{{$nope}}")
        #expect(result.unresolved == ["$nope"])
        #expect(result.text == "{{$nope}}")
    }

    @Test func systemDynamicVariablesProduceSensibleValues() {
        let dynamics = SystemDynamicVariables()
        let guid = try! #require(dynamics.value(for: "guid"))
        #expect(UUID(uuidString: guid) != nil)
        #expect(dynamics.value(for: "randomUUID") != nil)

        let timestamp = try! #require(dynamics.value(for: "timestamp"))
        #expect(Int(timestamp)! > 1_700_000_000)

        let iso = try! #require(dynamics.value(for: "isoTimestamp"))
        #expect(iso.contains("T"))

        let randomInt = try! #require(dynamics.value(for: "randomInt"))
        #expect((0...1000).contains(Int(randomInt)!))

        #expect(dynamics.value(for: "notARealName") == nil)
    }

    @Test func eachGuidOccurrenceIsDistinct() {
        let result = VariableResolver(values: [:]).resolve("{{$guid}} {{$guid}}")
        let parts = result.text.split(separator: " ")
        #expect(parts.count == 2)
        #expect(parts[0] != parts[1])
    }

    @Test func disabledVariablesAreInvisible() {
        let scope = VariableScope(layers: [VariableLayer(source: .globals, variables: [
            Variable(key: "a", value: "1", enabled: false),
            Variable(key: "b", value: "2"),
        ])])
        let result = VariableResolver(scope: scope).resolve("{{a}}{{b}}")
        #expect(result.text == "{{a}}2")
        #expect(result.unresolved == ["a"])
    }

    @Test func scopeReportsShadowedVariablesWithTheirSource() {
        let scope = VariableScope.test([
            (.environment(name: "Staging"), ["v": "env"]),
            (.collection(name: "Acme"), ["v": "collection"]),
        ])
        let all = scope.allVariables()
        #expect(all.count == 2)
        #expect(all[0].source == .environment(name: "Staging"))
        #expect(!all[0].isShadowed)
        #expect(all[1].source == .collection(name: "Acme"))
        #expect(all[1].isShadowed)
        #expect(scope.effectiveValues()["v"] == "env")
    }

    @Test func resolvesKeyValueRows() {
        let rows = [
            KeyValue(key: "limit", value: "{{n}}"),
            KeyValue(key: "off", value: "1", enabled: false),
        ]
        let resolved = resolver([(.globals, ["n": "10"])]).resolve(rows: rows)
        #expect(resolved.count == 1)
        #expect(resolved[0].key == "limit")
        #expect(resolved[0].value == "10")
    }

    @Test func tokenizesForTheURLBar() {
        let resolver = resolver([(.globals, ["host": "example.com"])], dynamics: ["guid": "g"])
        let input = #"https://{{host}}/{{missing}}/{{$guid}}/\{{skip}}"#
        let tokens = resolver.tokens(in: input)
        #expect(tokens.count == 3)
        #expect(tokens[0].name == "host")
        #expect(tokens[0].resolvedValue == "example.com")
        #expect(tokens[1].name == "missing")
        #expect(!tokens[1].isResolved)
        #expect(tokens[2].isDynamic)
        #expect(String(input[tokens[0].range]) == "{{host}}")
    }

    @Test func tokensKnowWhichVariablesAreSecret() {
        let scope = VariableScope(layers: [VariableLayer(source: .environment(name: "P"), variables: [
            Variable(key: "token", value: "abc", isSecret: true),
        ])])
        let tokens = VariableResolver(scope: scope).tokens(in: "Bearer {{token}}")
        #expect(tokens.count == 1)
        #expect(tokens[0].isSecret)
    }

    @Test func scopeBuildOrdersLayersCorrectly() {
        let environment = RequestEnvironment(name: "Staging", variables: [Variable(key: "a", value: "1")])
        let collection = RequestCollection(name: "C", variables: [Variable(key: "a", value: "3")])
        let folder = Folder(name: "F", variables: [Variable(key: "a", value: "2")])
        let scope = VariableScope.build(
            environment: environment, collection: collection,
            folderChain: [folder], globals: Globals(variables: [Variable(key: "a", value: "4")]))
        #expect(scope.layers.map(\.source) == [
            .environment(name: "Staging"), .folder(name: "F"),
            .collection(name: "C"), .globals,
        ])
    }
}
