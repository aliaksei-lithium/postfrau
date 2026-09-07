import Foundation

/// The syntax of a raw body, which drives highlighting and the default `Content-Type`.
public enum RawLanguage: String, Sendable, Hashable, Codable, CaseIterable {
    case json, text, xml, html, javascript

    public var displayName: String {
        switch self {
        case .json: "JSON"
        case .text: "Text"
        case .xml: "XML"
        case .html: "HTML"
        case .javascript: "JavaScript"
        }
    }

    /// The `Content-Type` Postfrau sends when the user has not set one explicitly.
    public var defaultContentType: String {
        switch self {
        case .json: "application/json"
        case .text: "text/plain"
        case .xml: "application/xml"
        case .html: "text/html"
        case .javascript: "application/javascript"
        }
    }
}

/// A reference to a file the user picked, kept as a security-scoped bookmark so the sandbox
/// still grants access after a relaunch. `displayName` is what the UI shows and what an
/// imported collection carries when the file itself is not available.
public struct FileReference: Sendable, Hashable, Codable {
    public var bookmark: Data?
    public var displayName: String

    public init(bookmark: Data? = nil, displayName: String = "") {
        self.bookmark = bookmark
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey { case bookmark, displayName }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
    }
}

/// The value of a multipart form field.
public enum FormValue: Sendable, Hashable, Codable {
    case text(String)
    case file(FileReference)

    private enum CodingKeys: String, CodingKey { case type, text, file }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .type) ?? "text" {
        case "file":
            self = .file(try c.decodeIfPresent(FileReference.self, forKey: .file) ?? FileReference())
        default:
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try c.encode("text", forKey: .type)
            try c.encode(value, forKey: .text)
        case .file(let reference):
            try c.encode("file", forKey: .type)
            try c.encode(reference, forKey: .file)
        }
    }
}

/// One `multipart/form-data` part.
public struct FormField: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var key: String
    public var enabled: Bool
    public var value: FormValue
    public var contentType: String?
    public var description: String?

    public init(
        id: UUID = UUID(),
        key: String = "",
        enabled: Bool = true,
        value: FormValue = .text(""),
        contentType: String? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.key = key
        self.enabled = enabled
        self.value = value
        self.contentType = contentType
        self.description = description
    }

    public var isEmpty: Bool {
        if case .text(let text) = value { return key.isEmpty && text.isEmpty }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case id, key, enabled, value, contentType, description
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        value = try c.decodeIfPresent(FormValue.self, forKey: .value) ?? .text("")
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }
}

/// What a request sends as its body.
///
/// Named `RequestBody` rather than `Body` so it does not collide with `View.Body` in the app layer.
public enum RequestBody: Sendable, Hashable, Codable {
    case none
    case raw(text: String, language: RawLanguage)
    case formData([FormField])
    case urlEncoded([KeyValue])
    case binary(FileReference)

    public var kind: Kind {
        switch self {
        case .none: .none
        case .raw: .raw
        case .formData: .formData
        case .urlEncoded: .urlEncoded
        case .binary: .binary
        }
    }

    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case none, raw, formData, urlEncoded, binary

        public var displayName: String {
            switch self {
            case .none: "None"
            case .raw: "Raw"
            case .formData: "Form Data"
            case .urlEncoded: "URL Encoded"
            case .binary: "Binary"
            }
        }
    }

    public static func empty(_ kind: Kind) -> RequestBody {
        switch kind {
        case .none: .none
        case .raw: .raw(text: "", language: .json)
        case .formData: .formData([])
        case .urlEncoded: .urlEncoded([])
        case .binary: .binary(FileReference())
        }
    }

    /// True when the body would put no bytes on the wire.
    public var isEffectivelyEmpty: Bool {
        switch self {
        case .none: true
        case .raw(let text, _): text.isEmpty
        case .formData(let fields): fields.allSatisfy { !$0.enabled || $0.key.isEmpty }
        case .urlEncoded(let rows): rows.active.isEmpty
        case .binary(let reference): reference.bookmark == nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, language, formData, urlEncoded, file
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(Kind.self, forKey: .type) ?? .none
        switch kind {
        case .none:
            self = .none
        case .raw:
            self = .raw(
                text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                language: try c.decodeIfPresent(RawLanguage.self, forKey: .language) ?? .json)
        case .formData:
            self = .formData(try c.decodeIfPresent([FormField].self, forKey: .formData) ?? [])
        case .urlEncoded:
            self = .urlEncoded(try c.decodeIfPresent([KeyValue].self, forKey: .urlEncoded) ?? [])
        case .binary:
            self = .binary(try c.decodeIfPresent(FileReference.self, forKey: .file) ?? FileReference())
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .type)
        switch self {
        case .none:
            break
        case .raw(let text, let language):
            try c.encode(text, forKey: .text)
            try c.encode(language, forKey: .language)
        case .formData(let fields):
            try c.encode(fields, forKey: .formData)
        case .urlEncoded(let rows):
            try c.encode(rows, forKey: .urlEncoded)
        case .binary(let reference):
            try c.encode(reference, forKey: .file)
        }
    }
}
