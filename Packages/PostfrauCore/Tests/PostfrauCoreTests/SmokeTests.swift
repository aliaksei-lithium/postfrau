import Testing
@testable import PostfrauCore

@Test func schemaVersionIsOne() {
    #expect(Postfrau.schemaVersion == 1)
}
