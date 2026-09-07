import Foundation
import Testing
@testable import PostfrauCore

/// A temporary directory that deletes itself when the test finishes with it.
struct TempDirectory: ~Copyable {
    let url: URL

    init(_ label: String = "postfrau-tests") {
        url = URL.temporaryDirectory.appending(
            path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Deterministic dynamic variables, so tests can assert on exact output.
struct FixedDynamicVariables: DynamicVariableProvider {
    var values: [String: String]

    func value(for name: String) -> String? { values[name] }
}

extension VariableScope {
    /// Builds a scope from plain dictionaries, highest precedence first.
    static func test(_ layers: [(VariableSource, [String: String])]) -> VariableScope {
        VariableScope(layers: layers.map { source, pairs in
            VariableLayer(
                source: source,
                variables: pairs
                    .sorted { $0.key < $1.key }
                    .map { Variable(key: $0.key, value: $0.value) })
        })
    }
}

/// A small but complete collection: two folders, three requests, nested one level.
func makeSampleCollection() -> RequestCollection {
    let inner = Folder(
        name: "Users",
        auth: .bearer(token: "{{folderToken}}"),
        variables: [Variable(key: "scope", value: "users")],
        items: [
            .request(RequestItem(name: "List", method: .get, url: "{{baseUrl}}/users")),
            .request(RequestItem(
                name: "Create", method: .post, url: "{{baseUrl}}/users",
                headers: [KeyValue(key: "X-Trace", value: "1")],
                body: .raw(text: "{\"name\":\"a\"}", language: .json))),
        ])
    let outer = Folder(name: "API", variables: [], items: [.folder(inner)])
    return RequestCollection(
        name: "Acme API",
        auth: .apiKey(key: "X-Key", value: "{{apiKey}}", location: .header),
        variables: [Variable(key: "baseUrl", value: "https://api.example.com")],
        items: [
            .folder(outer),
            .request(RequestItem(name: "Health", method: .get, url: "{{baseUrl}}/health")),
        ],
        createdAt: fixedDate,
        updatedAt: fixedDate)
}

/// Round-trips a value through the on-disk coders.
func roundTrip<T: Codable>(_ value: T) throws -> T {
    let data = try Postfrau.makeEncoder().encode(value)
    return try Postfrau.makeDecoder().decode(T.self, from: data)
}

/// A fixed timestamp with no sub-millisecond component, so it survives an ISO-8601 round trip
/// exactly and tests can compare whole models for equality.
let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
