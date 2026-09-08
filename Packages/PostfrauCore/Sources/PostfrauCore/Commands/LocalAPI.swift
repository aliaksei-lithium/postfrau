import Foundation
import Security

/// The contract between the app and a `postfrau` that cannot reach the workspace on disk.
///
/// An agent in a sandbox is the case this exists for. The app holds the security-scoped bookmark
/// to the data folder; a CLI in a sandbox that denies `~/Library/Containers` — or denies the
/// user's folder — can reach none of it. So the app offers the same operations over a loopback
/// socket and does the file access itself, and the CLI forwards to it when
/// `POSTFRAU_API_TOKEN` is set.
///
/// Deliberately small: list, detail, run, send. Enough to find a request and fire it, which is
/// what an agent needs. Editing a workspace still wants a real folder.
public enum LocalAPI {
    /// Chosen to be memorable and out of the way of the usual dev-server ports.
    public static let defaultPort = 7717
    public static let tokenVariable = "POSTFRAU_API_TOKEN"
    public static let urlVariable = "POSTFRAU_API_URL"

    public static func defaultURL(port: Int) -> String { "http://127.0.0.1:\(port)" }

    /// 32 bytes of `SecRandomCopyBytes`, base64url so it survives a shell without quoting.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // A failure here would mean the system RNG is unavailable, which is not a thing to paper
        // over with a weaker token.
        precondition(
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess,
            "the system random number generator is unavailable")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Compares two tokens without an early return.
    ///
    /// `==` on `String` stops at the first differing byte, and the time it takes to do that is
    /// measurable over a loopback socket — enough to recover a token one byte at a time. Length is
    /// allowed to leak; the token is fixed-length anyway.
    public static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard !a.isEmpty, a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }

    // MARK: - Wire types

    /// `GET /v1/ping` — what the CLI calls to decide whether the app is actually there.
    public struct Ping: Codable, Sendable {
        public var version: String
        public var dataFolder: String
        public init(version: String, dataFolder: String) {
            self.version = version
            self.dataFolder = dataFolder
        }
    }

    /// `GET /v1/list?path=&recursive=`
    public struct ListResult: Codable, Sendable {
        public var items: [ListedItem]
        public init(items: [ListedItem]) { self.items = items }
    }

    /// `POST /v1/run`
    public struct RunBody: Codable, Sendable {
        public var path: String
        public var environment: String?
        public var variables: [String: String]?
        public var captures: [String: String]?
        public var bodyCap: Int?
        public init(
            path: String, environment: String? = nil, variables: [String: String]? = nil,
            captures: [String: String]? = nil, bodyCap: Int? = nil
        ) {
            self.path = path
            self.environment = environment
            self.variables = variables
            self.captures = captures
            self.bodyCap = bodyCap
        }
    }

    /// `POST /v1/send` — the ad-hoc form, for a request that is not in any collection.
    public struct SendBody: Codable, Sendable {
        public var method: String
        public var url: String
        public var headers: [HeaderField]?
        public var body: String?
        public var environment: String?
        public var variables: [String: String]?
        public var captures: [String: String]?
        public var bodyCap: Int?
        public init(
            method: String, url: String, headers: [HeaderField]? = nil, body: String? = nil,
            environment: String? = nil, variables: [String: String]? = nil,
            captures: [String: String]? = nil, bodyCap: Int? = nil
        ) {
            self.method = method
            self.url = url
            self.headers = headers
            self.body = body
            self.environment = environment
            self.variables = variables
            self.captures = captures
            self.bodyCap = bodyCap
        }
    }

    /// Any non-2xx reply. The CLI prints `error` and nothing else.
    public struct Failure: Codable, Sendable {
        public var error: String
        public init(error: String) { self.error = error }
    }
}
