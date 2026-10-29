import Testing
@testable import PostfrauCore

@Suite("Sidebar URL subtitle")
struct URLSubtitleTests {
    @Test func dropsTheBaseVariableAndTheQuery() {
        #expect(URLSubtitle.text(
            for: #"{{baseUrl}}/v2/materialization/backfill-daily-interest?customer_id=["BAC_111"]"#)
            == "/v2/materialization/backfill-daily-interest")
    }

    @Test func keepsPathVariablesAsWritten() {
        #expect(URLSubtitle.text(for: "{{baseUrl}}/deposits/{{depositId}}/statement")
            == "/deposits/{{depositId}}/statement")
    }

    @Test func dropsTheSchemeOfALiteralURL() {
        #expect(URLSubtitle.text(for: "https://api.example.com/users?page=2#top")
            == "api.example.com/users")
    }

    @Test func aURLThatIsOnlyAVariableKeepsIt() {
        #expect(URLSubtitle.text(for: "{{healthUrl}}") == "{{healthUrl}}")
        #expect(URLSubtitle.text(for: "") == "")
    }
}
