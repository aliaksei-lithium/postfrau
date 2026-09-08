import Foundation

/// How much of an exchange is written to history.
///
/// The default records what makes an entry findable and re-sendable without keeping anything
/// sensitive around longer than it has to be. Headers and bodies are opt-in because a history file
/// holding real request bodies is a liability — it is redacted, but the less that is written the
/// less there is to leak.
public enum HistoryRecordLevel: String, Sendable, Hashable, Codable, CaseIterable {
    /// Nothing is written at all.
    case off
    /// Method, URL, status, timing, size, and the request without its body.
    case metadata
    /// The above plus request and response headers.
    case headers
    /// The above plus bodies, capped and redacted.
    case full

    public var displayName: String {
        switch self {
        case .off: "Don't record"
        case .metadata: "Metadata only"
        case .headers: "Headers"
        case .full: "Headers and bodies"
        }
    }

    public var explanation: String {
        switch self {
        case .off: "Sends are not written to history at all."
        case .metadata: "Method, URL, status, timing and size."
        case .headers: "Also the request and response headers, with secrets redacted."
        case .full: "Also the bodies, capped in size, with secrets redacted."
        }
    }

    public var recordsHeaders: Bool { self == .headers || self == .full }
    public var recordsBodies: Bool { self == .full }
}

/// Who sent a request.
///
/// Attribution is what makes an agent's actions auditable: every entry says whether it came from
/// the app, the `postfrau` CLI, or a named agent driving that CLI.
public enum HistorySource: Sendable, Hashable, Codable {
    case app
    case cli
    case agent(name: String)

    public var displayName: String {
        switch self {
        case .app: "App"
        case .cli: "CLI"
        case .agent(let name): name
        }
    }

    /// True for anything that was not a person clicking Send in the app.
    public var isAutomated: Bool {
        switch self {
        case .app: false
        case .cli, .agent: true
        }
    }

    public var symbolName: String {
        switch self {
        case .app: "macwindow"
        case .cli: "terminal"
        case .agent: "sparkles"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, name }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .type) ?? "app" {
        case "cli": self = .cli
        case "agent": self = .agent(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "agent")
        default: self = .app
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app: try c.encode("app", forKey: .type)
        case .cli: try c.encode("cli", forKey: .type)
        case .agent(let name):
            try c.encode("agent", forKey: .type)
            try c.encode(name, forKey: .name)
        }
    }
}

/// A body kept in a history entry, capped so one huge response cannot bloat the log.
public struct RecordedBody: Sendable, Hashable, Codable {
    public var data: Data
    /// True when `data` holds only the first `data.count` bytes of a larger body.
    public var truncated: Bool
    public var originalBytes: Int
    public var mimeType: String?

    public init(data: Data, truncated: Bool, originalBytes: Int, mimeType: String? = nil) {
        self.data = data
        self.truncated = truncated
        self.originalBytes = originalBytes
        self.mimeType = mimeType
    }

    /// Keeps at most `cap` bytes, recording how much was dropped.
    public static func capped(_ data: Data, cap: Int, mimeType: String? = nil) -> RecordedBody {
        RecordedBody(
            data: data.count > cap ? data.prefix(cap) : data,
            truncated: data.count > cap,
            originalBytes: data.count,
            mimeType: mimeType)
    }

    public var text: String { String(decoding: data, as: UTF8.self) }

    private enum CodingKeys: String, CodingKey { case data, truncated, originalBytes, mimeType }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decodeIfPresent(Data.self, forKey: .data) ?? Data()
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        originalBytes = try c.decodeIfPresent(Int.self, forKey: .originalBytes) ?? data.count
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
    }
}
