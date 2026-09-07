import Foundation
import Testing
@testable import PostfrauCore

@Suite("JSON pretty printer")
struct JSONPrettyPrinterTests {
    @Test func indentsAnObject() throws {
        let output = try JSONPrettyPrinter.prettyPrint(#"{"a":1,"b":"two"}"#)
        #expect(output == """
            {
              "a": 1,
              "b": "two"
            }
            """)
    }

    @Test func indentsNestedStructures() throws {
        let output = try JSONPrettyPrinter.prettyPrint(#"{"a":[1,{"b":[]}],"c":{}}"#)
        #expect(output == """
            {
              "a": [
                1,
                {
                  "b": []
                }
              ],
              "c": {}
            }
            """)
    }

    @Test func honoursTheIndentWidth() throws {
        let output = try JSONPrettyPrinter.prettyPrint(#"{"a":1}"#, indent: 4)
        #expect(output == "{\n    \"a\": 1\n}")
    }

    @Test func preservesKeyOrder() throws {
        let output = try JSONPrettyPrinter.prettyPrint(#"{"z":1,"m":2,"a":3}"#)
        let keys = output.split(separator: "\n").compactMap { line -> String? in
            guard let quote = line.firstIndex(of: "\"") else { return nil }
            let rest = line[line.index(after: quote)...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[rest.startIndex..<end])
        }
        #expect(keys == ["z", "m", "a"])
    }

    @Test func preservesDuplicateKeys() throws {
        let output = try JSONPrettyPrinter.prettyPrint(#"{"a":1,"a":2}"#)
        #expect(output.contains("\"a\": 1"))
        #expect(output.contains("\"a\": 2"))
    }

    @Test func preservesNumberPrecisionExactly() throws {
        // Every one of these is mangled by a JSONSerialization round-trip.
        let numbers = [
            "9007199254740993",            // beyond Double's exact integer range
            "1.0",                         // trailing .0 is meaningful to some APIs
            "1e400",                       // overflows Double
            "-0",
            "0.1000000000000000055511151231257827",
            "123456789012345678901234567890",
        ]
        for number in numbers {
            let output = try JSONPrettyPrinter.prettyPrint("{\"n\":\(number)}")
            #expect(output.contains("\"n\": \(number)"), "\(number) was rewritten")
        }
    }

    @Test func preservesStringEscapesAndUnicode() throws {
        let input = #"{"s":"a\"b\\c\ndé é 🎈 \/ "}"#
        let output = try JSONPrettyPrinter.prettyPrint(input)
        #expect(output.contains(#""s": "a\"b\\c\ndé é 🎈 \/ ""#))
    }

    @Test func aQuoteInsideAStringDoesNotEndIt() throws {
        let output = try JSONPrettyPrinter.prettyPrint(#"{"a":"}{\"","b":1}"#)
        #expect(output.contains(#""b": 1"#))
    }

    @Test func handlesTopLevelScalarsAndArrays() throws {
        #expect(try JSONPrettyPrinter.prettyPrint("42") == "42")
        #expect(try JSONPrettyPrinter.prettyPrint(#""hi""#) == #""hi""#)
        #expect(try JSONPrettyPrinter.prettyPrint("true") == "true")
        #expect(try JSONPrettyPrinter.prettyPrint("null") == "null")
        #expect(try JSONPrettyPrinter.prettyPrint("[]") == "[]")
        #expect(try JSONPrettyPrinter.prettyPrint("[1,2]") == "[\n  1,\n  2\n]")
    }

    @Test func normalisesExistingWhitespace() throws {
        let messy = "{\n\t\"a\"  :\n   1 ,   \"b\":\r\n2\n}"
        #expect(try JSONPrettyPrinter.prettyPrint(messy) == "{\n  \"a\": 1,\n  \"b\": 2\n}")
    }

    @Test func isIdempotent() throws {
        let once = try JSONPrettyPrinter.prettyPrint(#"{"a":[1,2],"b":{"c":null}}"#)
        #expect(try JSONPrettyPrinter.prettyPrint(once) == once)
    }

    @Test func minifiesBackToCompactJSON() throws {
        let pretty = try JSONPrettyPrinter.prettyPrint(#"{"a":[1,2],"b":"x y"}"#)
        #expect(try JSONPrettyPrinter.minify(pretty) == #"{"a":[1,2],"b":"x y"}"#)
    }

    @Test func rejectsMalformedInput() {
        let bad = [
            #"{"a":}"#, "{", "[1,", #"{"a" 1}"#, #"{"unterminated": "oops}"#, "", "   ",
            #"{"a":1} trailing"#,
        ]
        for input in bad {
            #expect(throws: (any Error).self, "should reject \(input)") {
                try JSONPrettyPrinter.prettyPrint(input)
            }
        }
    }

    @Test func errorsCarryAReadableMessage() {
        let error = JSONPrettyPrinter.PrintError.unterminatedString(offset: 12)
        #expect(error.errorDescription?.contains("12") == true)
        #expect(JSONPrettyPrinter.PrintError.unexpectedEnd.errorDescription?.isEmpty == false)
    }

    @Test func sniffsWhetherSomethingLooksLikeJSON() {
        #expect(JSONPrettyPrinter.looksLikeJSON(Data(#"  {"a":1}"#.utf8)))
        #expect(JSONPrettyPrinter.looksLikeJSON(Data("\n[1]".utf8)))
        #expect(!JSONPrettyPrinter.looksLikeJSON(Data("<html>".utf8)))
        #expect(!JSONPrettyPrinter.looksLikeJSON(Data()))
    }

    @Test func handlesADeeplyNestedDocument() throws {
        let depth = 200
        let input = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let output = try JSONPrettyPrinter.prettyPrint(input)
        #expect(output.contains("["))
        #expect(try JSONPrettyPrinter.minify(output) == input)
    }

    @Test(.timeLimit(.minutes(1)))
    func prettyPrintsTwoMegabytesWellUnderASecond() throws {
        // PLAN.md §6 Phase 5 sets the bar: a 2 MB body must pretty-print in under a second.
        var rows: [String] = []
        for index in 0..<40_000 {
            rows.append(#"{"id":\#(index),"name":"row \#(index)","score":\#(index).5,"ok":true}"#)
        }
        let input = "{\"rows\":[" + rows.joined(separator: ",") + "]}"
        #expect(input.utf8.count > 2_000_000)

        let started = ContinuousClock.now
        let output = try JSONPrettyPrinter.prettyPrint(input)
        let elapsed = started.duration(to: .now)

        #expect(output.utf8.count > input.utf8.count)
        #expect(elapsed < .seconds(1), "took \(elapsed)")
        // Precision survived the whole way through.
        #expect(output.contains("\"score\": 39999.5"))
    }
}

@Suite("Key/value row editing")
struct KeyValueRowsTests {
    @Test func addsATrailingBlankRow() {
        let rows = KeyValueRows.withTrailingBlank([KeyValue(key: "a", value: "1")])
        #expect(rows.count == 2)
        #expect(rows[0].key == "a")
        #expect(rows[1].isEmpty)
    }

    @Test func keepsExactlyOneBlankRow() {
        let rows = KeyValueRows.withTrailingBlank([
            KeyValue(key: "a", value: "1"), KeyValue(), KeyValue(),
        ])
        #expect(rows.count == 2)
        #expect(rows.last?.isEmpty == true)
    }

    @Test func dropsBlankRowsFromTheMiddle() {
        let rows = KeyValueRows.withTrailingBlank([
            KeyValue(key: "a", value: "1"), KeyValue(), KeyValue(key: "b", value: "2"),
        ])
        #expect(rows.map(\.key) == ["a", "b", ""])
    }

    @Test func reusesTheExistingBlankRowsIdentity() {
        // Otherwise the field the user is typing in loses focus on every keystroke.
        let blank = KeyValue()
        let rows = KeyValueRows.withTrailingBlank([KeyValue(key: "a", value: "1"), blank])
        #expect(rows.last?.id == blank.id)
    }

    @Test func anEmptyListStillGetsARowToTypeInto() {
        #expect(KeyValueRows.withTrailingBlank([]).count == 1)
    }

    @Test func aRowWithOnlyADescriptionCountsAsUsed() {
        let annotated = KeyValue(key: "", value: "", description: "note")
        #expect(!annotated.isEmpty)
        #expect(KeyValueRows.stripped([annotated]).count == 1)
    }

    @Test func strippingRemovesEveryBlankRow() {
        #expect(KeyValueRows.stripped([KeyValue(), KeyValue(key: "a"), KeyValue()]).count == 1)
    }

    @Test func formFieldsFollowTheSameRules() {
        let fields = [FormField(key: "a", value: .text("1")), FormField()].withTrailingBlank
        #expect(fields.count == 2)
        #expect(fields.last?.isEmpty == true)
        #expect([FormField(key: "a"), FormField()].stripped.count == 1)
    }

    @Test func aFileFormFieldIsNeverBlank() {
        let file = FormField(key: "", value: .file(FileReference(displayName: "a.png")))
        #expect(!file.isEmpty)
    }

    @Test func normalizingARequestDropsEditorScaffolding() {
        var request = RequestItem(name: "R", url: "https://x.test")
        request.params = [KeyValue(key: "a", value: "1"), KeyValue()]
        request.headers = [KeyValue()]
        request.body = .urlEncoded([KeyValue(key: "b", value: "2"), KeyValue()])

        let normalized = request.normalized()
        #expect(normalized.params.count == 1)
        #expect(normalized.headers.isEmpty)
        if case .urlEncoded(let rows) = normalized.body {
            #expect(rows.count == 1)
        } else {
            Issue.record("body mode changed")
        }
    }

    @Test func normalizingMakesAnUntouchedTabCompareEqual() {
        // Visiting the Params tab appends a blank row; that must not look like an unsaved edit.
        let saved = RequestItem(name: "R", url: "https://x.test")
        var visited = saved
        visited.params = KeyValueRows.withTrailingBlank(saved.params)
        visited.headers = KeyValueRows.withTrailingBlank(saved.headers)

        #expect(visited != saved)
        #expect(visited.normalized() == saved.normalized())
    }
}

@Suite("Header catalog")
struct HeaderCatalogTests {
    @Test func completesByPrefixCaseInsensitively() {
        #expect(HeaderCatalog.completions(for: "cont").contains("Content-Type"))
        #expect(HeaderCatalog.completions(for: "CONT").contains("Content-Type"))
        #expect(HeaderCatalog.completions(for: "auth").first == "Authorization")
    }

    @Test func fallsBackToAContainsMatch() {
        // "type" is not a prefix of anything, but it should still find Content-Type.
        #expect(HeaderCatalog.completions(for: "type").contains("Content-Type"))
    }

    @Test func prefixMatchesOutrankContainsMatches() {
        let results = HeaderCatalog.completions(for: "co")
        let firstContains = results.firstIndex { !$0.lowercased().hasPrefix("co") } ?? results.count
        let lastPrefix = results.lastIndex { $0.lowercased().hasPrefix("co") } ?? -1
        #expect(lastPrefix < firstContains)
    }

    @Test func returnsNothingForAnEmptyPrefix() {
        #expect(HeaderCatalog.completions(for: "").isEmpty)
        #expect(HeaderCatalog.completions(for: "   ").isEmpty)
    }

    @Test func honoursTheLimit() {
        #expect(HeaderCatalog.completions(for: "a", limit: 3).count <= 3)
    }

    @Test func suggestsValuesForTheHeadersWhereItHelps() {
        #expect(HeaderCatalog.valueCompletions(forHeader: "Content-Type", prefix: "json")
            .contains("application/json"))
        #expect(HeaderCatalog.valueCompletions(forHeader: "content-type", prefix: "")
            .contains("application/json"))
        #expect(HeaderCatalog.valueCompletions(forHeader: "Cache-Control", prefix: "no")
            .contains("no-cache"))
        #expect(HeaderCatalog.valueCompletions(forHeader: "X-Whatever", prefix: "a").isEmpty)
    }
}
