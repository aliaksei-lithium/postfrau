import Foundation
import Testing
@testable import PostfrauCore

/// Reads a tokenizer's output back as `(kind, text)` pairs, which is far easier to assert on than
/// raw offsets — and checks the offsets are right as a side effect.
private func runs(_ highlighter: any SyntaxHighlighter, _ text: String) -> [(SyntaxKind, String)] {
    let units = Array(text.utf16)
    return highlighter.tokens(in: text).map { token in
        let slice = units[token.location..<(token.location + token.length)]
        return (token.kind, String(decoding: slice, as: UTF16.self))
    }
}

@Suite("JSON highlighter")
struct JSONHighlighterTests {
    private let highlighter = JSONHighlighter()

    @Test func tellsKeysApartFromStringValues() {
        let output = runs(highlighter, #"{"name":"ada"}"#)
        #expect(output.contains { $0 == .key && $1 == "\"name\"" })
        #expect(output.contains { $0 == .string && $1 == "\"ada\"" })
    }

    @Test func aStringFollowedByWhitespaceThenColonIsStillAKey() {
        let output = runs(highlighter, "{\"name\"  :\n \"ada\"}")
        #expect(output.first { $1 == "\"name\"" }?.0 == .key)
    }

    @Test func stringsInsideArraysAreValuesNotKeys() {
        let output = runs(highlighter, #"["a","b"]"#)
        #expect(output.filter { $0.0 == .string }.count == 2)
        #expect(!output.contains { $0.0 == .key })
    }

    @Test func tokenizesNumbersIncludingExponentsAndNegatives() {
        let output = runs(highlighter, #"[1,-2,3.5,1e10,-1.2E-3]"#)
        let numbers = output.filter { $0.0 == .number }.map(\.1)
        #expect(numbers == ["1", "-2", "3.5", "1e10", "-1.2E-3"])
    }

    @Test func tokenizesLiterals() {
        let output = runs(highlighter, "[true,false,null]")
        #expect(output.filter { $0.0 == .keyword }.map(\.1) == ["true", "false", "null"])
    }

    @Test func tokenizesPunctuation() {
        let output = runs(highlighter, #"{"a":[1]}"#)
        #expect(output.filter { $0.0 == .punctuation }.map(\.1) == ["{", ":", "[", "]", "}"])
    }

    @Test func escapedQuotesDoNotEndAString() {
        let output = runs(highlighter, #"{"a":"b\"c:d"}"#)
        #expect(output.contains { $0 == .string && $1 == #""b\"c:d""# })
        // The `:` inside the string must not have been read as punctuation.
        #expect(output.filter { $0.0 == .punctuation }.map(\.1) == ["{", ":", "}"])
    }

    @Test func handlesNonASCIIOffsetsCorrectly() {
        // Emoji are surrogate pairs in UTF-16; the offsets must still line up.
        let text = #"{"emoji":"🎈 é","n":1}"#
        let output = runs(highlighter, text)
        #expect(output.contains { $0 == .string && $1 == #""🎈 é""# })
        #expect(output.contains { $0 == .number && $1 == "1" })
    }

    @Test func tokensAreOrderedAndNonOverlapping() {
        let tokens = highlighter.tokens(in: #"{"a":[1,"b",true],"c":null}"#)
        for (previous, next) in zip(tokens, tokens.dropFirst()) {
            #expect(previous.location + previous.length <= next.location)
        }
    }

    @Test func malformedJSONStillProducesTokens() {
        // A truncated response must still be readable.
        for input in [#"{"a":"#, #"{"a": "unterminated"#, "[1,2,", "}{"] {
            #expect(!highlighter.tokens(in: input).isEmpty, "no tokens for \(input)")
        }
    }

    @Test func emptyInputProducesNoTokens() {
        #expect(highlighter.tokens(in: "").isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func tokenizesTwoMegabytesQuickly() {
        var rows: [String] = []
        for index in 0..<50_000 {
            rows.append(#"{"id":\#(index),"name":"row \#(index)","ok":true}"#)
        }
        let input = "{\"rows\":[" + rows.joined(separator: ",") + "]}"
        #expect(input.utf16.count > 2_000_000)

        let started = ContinuousClock.now
        let tokens = highlighter.tokens(in: input)
        let elapsed = started.duration(to: .now)

        #expect(tokens.count > 100_000)
        #expect(elapsed < .seconds(1), "took \(elapsed)")
    }

    @Test func stopsAtTheHighlightLimit() {
        let huge = String(repeating: "\"x\",", count: 2_000_000)
        let tokens = highlighter.tokens(in: huge)
        let end = tokens.last.map { $0.location + $0.length } ?? 0
        #expect(end <= JSONHighlighter.highlightLimit)
    }
}

@Suite("XML highlighter")
struct XMLHighlighterTests {
    private let highlighter = XMLHighlighter()

    @Test func tokenizesTagsAttributesAndText() {
        let output = runs(highlighter, #"<a href="x">hi</a>"#)
        #expect(output.contains { $0 == .tagName && $1 == "a" })
        #expect(output.contains { $0 == .attributeName && $1 == "href" })
        #expect(output.contains { $0 == .attributeValue && $1 == "\"x\"" })
        #expect(output.contains { $0 == .text && $1 == "hi" })
    }

    @Test func handlesSelfClosingTags() {
        let output = runs(highlighter, #"<br/><img src="a.png" />"#)
        #expect(output.filter { $0.0 == .tagName }.map(\.1) == ["br", "img"])
        #expect(output.contains { $0 == .attributeValue && $1 == "\"a.png\"" })
    }

    @Test func handlesClosingTags() {
        let output = runs(highlighter, "<p></p>")
        #expect(output.filter { $0.0 == .tagName }.map(\.1) == ["p", "p"])
    }

    @Test func tokenizesComments() {
        let output = runs(highlighter, "<a><!-- a > b --></a>")
        #expect(output.contains { $0 == .comment && $1 == "<!-- a > b -->" })
    }

    @Test func tokenizesDeclarationsAndDoctypes() {
        let output = runs(highlighter, "<?xml version=\"1.0\"?><!DOCTYPE html><p>x</p>")
        #expect(output.contains { $0.0 == .comment && $0.1.hasPrefix("<?xml") })
        #expect(output.contains { $0.0 == .comment && $0.1.hasPrefix("<!DOCTYPE") })
    }

    @Test func handlesSingleQuotedAndUnquotedAttributeValues() {
        let output = runs(highlighter, "<a b='c' d=e>x</a>")
        #expect(output.contains { $0 == .attributeValue && $1 == "'c'" })
        #expect(output.contains { $0 == .attributeValue && $1 == "e" })
    }

    @Test func aGreaterThanInsideAnAttributeDoesNotEndTheTag() {
        let output = runs(highlighter, #"<a title="x > y">t</a>"#)
        #expect(output.contains { $0 == .attributeValue && $1 == #""x > y""# })
        #expect(output.contains { $0 == .text && $1 == "t" })
    }

    @Test func whitespaceOnlyTextIsNotATextToken() {
        let output = runs(highlighter, "<a>\n  <b>x</b>\n</a>")
        #expect(output.filter { $0.0 == .text }.map(\.1) == ["x"])
    }

    @Test func cdataIsOneToken() {
        let output = runs(highlighter, "<a><![CDATA[<not> a tag]]></a>")
        #expect(output.contains { $0 == .text && $1 == "<![CDATA[<not> a tag]]>" })
    }

    @Test func malformedMarkupStillProducesTokens() {
        for input in ["<a", "<a href=", "</", "<<>>", "<a><b>"] {
            _ = highlighter.tokens(in: input)  // must terminate
        }
        #expect(!highlighter.tokens(in: "<a").isEmpty)
    }

    @Test func tokensAreOrderedAndNonOverlapping() {
        let tokens = highlighter.tokens(in: #"<r><a x="1">t</a><!--c--><b/></r>"#)
        for (previous, next) in zip(tokens, tokens.dropFirst()) {
            #expect(previous.location + previous.length <= next.location)
        }
    }
}

@Suite("XML pretty printer")
struct XMLPrettyPrinterTests {
    @Test func indentsNestedElements() throws {
        let output = try XMLPrettyPrinter.prettyPrint("<a><b><c>x</c></b></a>")
        #expect(output == """
            <a>
              <b>
                <c>x</c>
              </b>
            </a>
            """)
    }

    @Test func keepsALoneTextChildOnOneLine() throws {
        #expect(try XMLPrettyPrinter.prettyPrint("<a>hello</a>") == "<a>hello</a>")
    }

    @Test func preservesAttributesExactly() throws {
        let input = #"<a href="x" data-b='y' checked>t</a>"#
        let output = try XMLPrettyPrinter.prettyPrint(input)
        #expect(output.contains(#"href="x" data-b='y' checked"#))
    }

    @Test func normalisesExistingIndentation() throws {
        let messy = "<a>\n\n      <b>1</b>\n<b>2</b>\n   </a>"
        #expect(try XMLPrettyPrinter.prettyPrint(messy) == """
            <a>
              <b>1</b>
              <b>2</b>
            </a>
            """)
    }

    @Test func handlesSelfClosingAndVoidElements() throws {
        let output = try XMLPrettyPrinter.prettyPrint("<div><br><img src=\"a\"/><p>x</p></div>")
        #expect(output == """
            <div>
              <br>
              <img src="a"/>
              <p>x</p>
            </div>
            """)
    }

    @Test func keepsCommentsProcessingInstructionsAndDoctypes() throws {
        let output = try XMLPrettyPrinter.prettyPrint(
            "<?xml version=\"1.0\"?><!-- note --><r><a/></r>")
        #expect(output.contains("<?xml version=\"1.0\"?>"))
        #expect(output.contains("<!-- note -->"))
    }

    @Test func leavesPreformattedContentAlone() throws {
        let output = try XMLPrettyPrinter.prettyPrint(
            "<div><pre>  keep\n   this  </pre></div>")
        #expect(output.contains("  keep\n   this  "))
    }

    @Test func honoursTheIndentWidth() throws {
        #expect(try XMLPrettyPrinter.prettyPrint("<a><b>x</b></a>", indent: 4)
            == "<a>\n    <b>x</b>\n</a>")
    }

    @Test func rejectsSomethingThatIsNotMarkup() {
        #expect(throws: XMLPrettyPrinter.PrintError.notMarkup) {
            try XMLPrettyPrinter.prettyPrint("just some text")
        }
        #expect(XMLPrettyPrinter.PrintError.notMarkup.errorDescription?.isEmpty == false)
    }

    @Test func toleratesUnbalancedMarkup() throws {
        // A truncated response must not throw or hang.
        let output = try XMLPrettyPrinter.prettyPrint("<a><b>x</a>")
        #expect(output.contains("<b>"))
    }
}

@Suite("Content type sniffer")
struct ContentTypeSnifferTests {
    @Test func trustsAnUnambiguousHeader() {
        #expect(ContentTypeSniffer.kind(mimeType: "application/json", bytes: Data()) == .json)
        #expect(ContentTypeSniffer.kind(mimeType: "application/vnd.api+json", bytes: Data()) == .json)
        #expect(ContentTypeSniffer.kind(mimeType: "application/problem+json", bytes: Data()) == .json)
        #expect(ContentTypeSniffer.kind(mimeType: "text/xml", bytes: Data()) == .xml)
        #expect(ContentTypeSniffer.kind(mimeType: "application/rss+xml", bytes: Data()) == .xml)
        #expect(ContentTypeSniffer.kind(mimeType: "text/html", bytes: Data()) == .html)
        #expect(ContentTypeSniffer.kind(mimeType: "application/pdf", bytes: Data()) == .pdf)
        #expect(ContentTypeSniffer.kind(mimeType: "image/png", bytes: Data()) == .image("png"))
    }

    @Test func ignoresParametersOnTheHeader() {
        #expect(ContentTypeSniffer.kind(
            mimeType: "application/json; charset=utf-8", bytes: Data()) == .json)
        #expect(ContentTypeSniffer.kind(mimeType: "  TEXT/HTML  ", bytes: Data()) == .html)
    }

    @Test func sniffsWhenTheHeaderIsUnhelpful() {
        // APIs mislabel JSON constantly; the bytes are the tiebreak.
        #expect(ContentTypeSniffer.kind(
            mimeType: "text/plain", bytes: Data(#"{"a":1}"#.utf8)) == .json)
        #expect(ContentTypeSniffer.kind(
            mimeType: "application/octet-stream", bytes: Data("[1,2]".utf8)) == .json)
        #expect(ContentTypeSniffer.kind(
            mimeType: nil, bytes: Data("<!DOCTYPE html><html>".utf8)) == .html)
        #expect(ContentTypeSniffer.kind(mimeType: nil, bytes: Data("<root/>".utf8)) == .xml)
        #expect(ContentTypeSniffer.kind(mimeType: nil, bytes: Data("hello".utf8)) == .text)
    }

    @Test func recognisesBinarySignatures() {
        #expect(ContentTypeSniffer.sniff(Data([0x25, 0x50, 0x44, 0x46, 0x2D])) == .pdf)
        #expect(ContentTypeSniffer.sniff(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])) == .image("png"))
        #expect(ContentTypeSniffer.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0])) == .image("jpeg"))
        #expect(ContentTypeSniffer.sniff(Data([0x47, 0x49, 0x46, 0x38, 0x39])) == .image("gif"))
    }

    @Test func treatsBytesWithNulsAsBinary() {
        #expect(ContentTypeSniffer.sniff(Data([0x01, 0x00, 0x02, 0x03])) == .binary)
    }

    @Test func skipsAByteOrderMarkAndLeadingWhitespace() {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data("\n\t {\"a\":1}".utf8))
        #expect(ContentTypeSniffer.sniff(bytes) == .json)
    }

    @Test func anEmptyBodyIsText() {
        #expect(ContentTypeSniffer.sniff(Data()) == .text)
    }

    @Test func describesWhatEachKindSupports() {
        #expect(ContentKind.json.isTextual)
        #expect(ContentKind.json.canPrettyPrint)
        #expect(!ContentKind.text.canPrettyPrint)
        #expect(!ContentKind.pdf.isTextual)
        #expect(!ContentKind.image("png").isTextual)
    }

    @Test func picksTheRightHighlighterForEachKind() {
        #expect(Highlighters.forContent(.json) is JSONHighlighter)
        #expect(Highlighters.forContent(.xml) is XMLHighlighter)
        #expect(Highlighters.forContent(.html) is XMLHighlighter)
        #expect(Highlighters.forContent(.text) == nil)
        #expect(Highlighters.forContent(.binary) == nil)
    }
}
