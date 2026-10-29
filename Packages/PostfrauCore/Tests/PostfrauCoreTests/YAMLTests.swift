import Foundation
import Testing
@testable import PostfrauCore

@Suite("YAML subset")
struct YAMLTests {
    private func parse(_ text: String) throws -> JSONValue { try YAML.parse(text) }

    // MARK: - Scalars

    @Test func resolvesScalarsByTheCoreSchema() throws {
        let value = try parse("""
        a: 1
        b: -2.5
        c: true
        d: null
        e: ~
        f:
        g: hello world
        h: 3.0.3
        i: yes
        j: 0042
        k: 1e3
        """)
        #expect(value["a"] == .number("1"))
        #expect(value["b"] == .number("-2.5"))
        #expect(value["c"] == .bool(true))
        #expect(value["d"] == .null)
        #expect(value["e"] == .null)
        #expect(value["f"] == .null)
        #expect(value["g"] == .string("hello world"))
        #expect(value["h"] == .string("3.0.3"))
        #expect(value["i"] == .string("yes"), "YAML 1.2: yes is a string")
        #expect(value["j"] == .string("0042"), "a leading zero is an identifier")
        #expect(value["k"] == .number("1e3"))
    }

    @Test func readsQuotedScalarsAndTheirEscapes() throws {
        let value = try parse(#"""
        a: "line\nbreak \"quoted\" é"
        b: 'it''s # not a comment'
        c: "true"
        "d e": x
        'f': y
        """#)
        #expect(value["a"] == .string("line\nbreak \"quoted\" é"))
        #expect(value["b"] == .string("it's # not a comment"))
        #expect(value["c"] == .string("true"), "a quoted scalar is always a string")
        #expect(value["d e"] == .string("x"))
        #expect(value["f"] == .string("y"))
    }

    @Test func stripsCommentsButNotHashesInsideValues() throws {
        let value = try parse("""
        # a header comment
        url: https://example.com/a#fragment   # trailing
        color: "#fff"
        """)
        #expect(value["url"] == .string("https://example.com/a#fragment"))
        #expect(value["color"] == .string("#fff"))
    }

    @Test func foldsMultiLinePlainAndQuotedScalars() throws {
        let value = try parse("""
        description: This runs
          onto a second line

          and a paragraph.
        quoted: "one
          two"
        next: 1
        """)
        #expect(value["description"] == .string("This runs onto a second line\nand a paragraph."))
        #expect(value["quoted"] == .string("one two"))
        #expect(value["next"] == .number("1"))
    }

    // MARK: - Block scalars

    @Test func literalBlockKeepsLineBreaks() throws {
        let value = try parse("""
        a: |
          first
            indented
          last
        b: |-
          stripped
        c: |+
          kept

        d: x
        """)
        #expect(value["a"] == .string("first\n  indented\nlast\n"))
        #expect(value["b"] == .string("stripped"))
        #expect(value["c"] == .string("kept\n\n"))
        #expect(value["d"] == .string("x"))
    }

    @Test func foldedBlockJoinsLines() throws {
        let value = try parse("""
        a: >
          one
          two

          three
        b: >-
          only
        """)
        #expect(value["a"] == .string("one two\nthree\n"))
        #expect(value["b"] == .string("only"))
    }

    @Test func blockScalarMayContainHashesAndColons() throws {
        let value = try parse("""
        a: |
          # not a comment
          key: not a mapping
        """)
        #expect(value["a"] == .string("# not a comment\nkey: not a mapping\n"))
    }

    // MARK: - Collections

    @Test func readsNestedMappingsAndSequences() throws {
        let value = try parse("""
        paths:
          /users/{id}:
            get:
              tags: [Users, "Admin"]
              parameters:
                - name: id
                  in: path
                  required: true
                - name: q
                  in: query
        list:
        - a
        - b
        """)
        let get = value["paths"]?["/users/{id}"]?["get"]
        #expect(get?["tags"] == .array([.string("Users"), .string("Admin")]))
        let parameters = try #require(get?["parameters"]?.arrayValue)
        #expect(parameters.count == 2)
        #expect(parameters[0]["name"] == .string("id"))
        #expect(parameters[0]["required"] == .bool(true))
        #expect(parameters[1]["in"] == .string("query"))
        #expect(value["list"] == .array([.string("a"), .string("b")]))
    }

    @Test func readsFlowMappingsAcrossLines() throws {
        let value = try parse("""
        example: {id: 1, name: "Rex",
          tags: [a, b], url: http://x/y}
        empty: []
        none: {}
        """)
        #expect(value["example"] == .object([
            "id": .number("1"), "name": .string("Rex"),
            "tags": .array([.string("a"), .string("b")]),
            "url": .string("http://x/y"),
        ]))
        #expect(value["empty"] == .array([]))
        #expect(value["none"] == .object([:]))
    }

    @Test func readsNestedSequenceItems() throws {
        let value = try parse("""
        - - a
          - b
        - c
        """)
        #expect(value == .array([.array([.string("a"), .string("b")]), .string("c")]))
    }

    @Test func numericKeysAreStrings() throws {
        let value = try parse("""
        responses:
          200:
            description: OK
          '404':
            description: Missing
        """)
        #expect(value["responses"]?["200"]?["description"] == .string("OK"))
        #expect(value["responses"]?["404"]?["description"] == .string("Missing"))
    }

    // MARK: - Anchors

    @Test func resolvesAnchorsAliasesAndMergeKeys() throws {
        let value = try parse("""
        base: &base
          type: string
          format: uuid
        copy: *base
        merged:
          <<: *base
          format: date
        list:
          - &item {a: 1}
          - *item
        """)
        #expect(value["copy"] == value["base"])
        #expect(value["merged"] == .object(["type": .string("string"), "format": .string("date")]))
        #expect(value["list"]?.arrayValue?.count == 2)
        #expect(value["list"]?.arrayValue?[1] == .object(["a": .number("1")]))
    }

    // MARK: - Documents and errors

    @Test func readsOnlyTheFirstDocument() throws {
        let value = try parse("""
        %YAML 1.2
        ---
        a: 1
        ---
        b: 2
        """)
        #expect(value == .object(["a": .number("1")]))
    }

    @Test func reportsTheLineOfAnError() throws {
        #expect(throws: YAML.ParseError.self) {
            try parse("""
            a:
              b: 1
             c: 2
            """)
        }
        do {
            _ = try parse("a: \"unclosed\nb: 1")
            Issue.record("expected an error")
        } catch let error as YAML.ParseError {
            #expect(error.line == 1)
        }
    }

    @Test func handlesWindowsLineEndingsAndABOM() throws {
        let value = try parse("\u{FEFF}a: 1\r\nb: two\r\n")
        #expect(value == .object(["a": .number("1"), "b": .string("two")]))
    }

    @Test func aYAMLSpecMatchesItsJSONForm() throws {
        let json = try Postfrau.makeDecoder().decode(
            JSONValue.self, from: fixture("petstore.openapi.json"))
        let yaml = try YAML.parse(fixture("petstore.openapi.yaml"))
        #expect(yaml == json)
    }
}
