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
/// Deliberately small: list, find, detail, run, send. Enough to find a request and fire it,
/// which is what an agent needs. Editing a workspace still wants a real folder.
public enum LocalAPI {
    /// Chosen to be memorable and out of the way of the usual dev-server ports.
    public static let defaultPort = 7717
    public static let tokenVariable = "POSTFRAU_API_TOKEN"
    public static let urlVariable = "POSTFRAU_API_URL"

    public static func defaultURL(port: Int) -> String { "http://127.0.0.1:\(port)" }

    /// What this build of the app understands beyond the original contract, reported by `ping`.
    ///
    /// An app that predates a field ignores it — JSON decoding drops unknown keys — so a tool that
    /// sends `--body` to an older app gets the saved body sent instead, with nothing to say so.
    /// The tool asks first and refuses rather than let that happen.
    public static let capabilities = [
        Capability.requestPatch, Capability.requestParams, Capability.strictFields,
    ]

    public enum Capability {
        /// `RunBody.patch`: `--body`, `--field` and `--header` on `run`.
        public static let requestPatch = "request-patch"
        /// `--param` and `--auth` on `run` (`RequestPatch.params`, `.auth`) and on `send`
        /// (`SendBody.params`, `.auth`, `.verifyTLS`, `.followRedirects`); `--secret`, `--as` and
        /// `--record` on both (`captureAsSecret`, `agent`, `record`).
        public static let requestParams = "request-params"
        /// The app answers 400 to a field it does not know instead of dropping it. From here on,
        /// a newer tool talking to an older app fails loudly rather than sending less than asked.
        public static let strictFields = "strict-fields"
    }

    /// Decodes a request body, refusing any field this build does not know.
    ///
    /// `JSONDecoder` drops unknown keys, which is how `--param` sent to an app that predates it
    /// came back 200 with the param never sent. Checked one level down as well, for `patch`.
    public static func decodeStrictly<T: StrictBody>(_ type: T.Type, from data: Data) throws -> T {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let object else { throw BodyError.malformed }
        var unknown = object.keys.filter { !T.fields.contains($0) }.sorted()
        if let patch = object["patch"] as? [String: Any] {
            unknown += patch.keys.filter { !RequestPatch.fields.contains($0) }.sorted()
                .map { "patch.\($0)" }
        }
        guard unknown.isEmpty else { throw BodyError.unknownFields(unknown) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BodyError.malformed
        }
    }

    public protocol StrictBody: Decodable {
        /// Every top-level field this build reads.
        static var fields: Set<String> { get }
    }

    public enum BodyError: Error, LocalizedError {
        case malformed
        case unknownFields([String])

        public var errorDescription: String? {
            switch self {
            case .malformed: "the request body is not the JSON this route takes."
            case .unknownFields(let names):
                "this Postfrau does not understand \(names.joined(separator: ", ")), so it sent "
                    + "nothing rather than send less than was asked. Update the app."
            }
        }
    }

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
        /// Nil from an app older than the field, which supports none of them.
        public var capabilities: [String]?
        public init(
            version: String, dataFolder: String,
            capabilities: [String]? = LocalAPI.capabilities
        ) {
            self.version = version
            self.dataFolder = dataFolder
            self.capabilities = capabilities
        }
    }

    /// `GET /v1/list?path=&recursive=`
    public struct ListResult: Codable, Sendable {
        public var items: [ListedItem]
        public init(items: [ListedItem]) { self.items = items }
    }

    /// `GET /v1/find?q=&limit=`
    public struct FindResult: Codable, Sendable {
        public var items: [FoundItem]
        public init(items: [FoundItem]) { self.items = items }
    }

    /// `POST /v1/run`
    public struct RunBody: Codable, Sendable, StrictBody {
        public static let fields: Set<String> = [
            "path", "environment", "variables", "captures", "bodyCap", "dryRun", "patch",
            "captureAsSecret", "agent", "record",
        ]
        public var path: String
        public var environment: String?
        public var variables: [String: String]?
        public var captures: [String: String]?
        public var bodyCap: Int?
        /// Build the request and describe it, but do not send it. Absent means send — an older
        /// app talking to a newer tool would otherwise silently do the opposite of what was
        /// asked, which for this flag is the dangerous direction.
        public var dryRun: Bool?
        /// `--body`, `--field`, `--header`. Only sent once `ping` has said the app understands it.
        public var patch: RequestPatch?
        /// `--secret`: store captured values as secrets.
        public var captureAsSecret: Bool?
        /// `--as` / `POSTFRAU_AGENT`: who history says sent it. The app's own label when absent.
        public var agent: String?
        /// `--record`: the history level for this send.
        public var record: String?
        public init(
            path: String, environment: String? = nil, variables: [String: String]? = nil,
            captures: [String: String]? = nil, bodyCap: Int? = nil, dryRun: Bool? = nil,
            patch: RequestPatch? = nil, captureAsSecret: Bool? = nil, agent: String? = nil,
            record: String? = nil
        ) {
            self.patch = patch
            self.captureAsSecret = captureAsSecret
            self.agent = agent
            self.record = record
            self.path = path
            self.environment = environment
            self.variables = variables
            self.captures = captures
            self.bodyCap = bodyCap
            self.dryRun = dryRun
        }
    }

    /// `POST /v1/send` — the ad-hoc form, for a request that is not in any collection.
    public struct SendBody: Codable, Sendable, StrictBody {
        public static let fields: Set<String> = [
            "method", "url", "headers", "body", "environment", "variables", "captures", "bodyCap",
            "dryRun", "params", "auth", "verifyTLS", "followRedirects", "captureAsSecret",
            "agent", "record",
        ]
        public var method: String
        public var url: String
        public var headers: [HeaderField]?
        public var body: String?
        public var environment: String?
        public var variables: [String: String]?
        public var captures: [String: String]?
        public var bodyCap: Int?
        public var dryRun: Bool?
        /// `--param`, in order; a name may repeat.
        public var params: [RequestPatch.QueryParam]?
        /// `--auth`. Checked like `run --auth`: a value that does not resolve is refused.
        public var auth: Auth?
        /// `--insecure` sends false.
        public var verifyTLS: Bool?
        /// `--no-redirects` sends false.
        public var followRedirects: Bool?
        public var captureAsSecret: Bool?
        public var agent: String?
        public var record: String?
        public init(
            method: String, url: String, headers: [HeaderField]? = nil, body: String? = nil,
            environment: String? = nil, variables: [String: String]? = nil,
            captures: [String: String]? = nil, bodyCap: Int? = nil, dryRun: Bool? = nil,
            params: [RequestPatch.QueryParam]? = nil, auth: Auth? = nil,
            verifyTLS: Bool? = nil, followRedirects: Bool? = nil,
            captureAsSecret: Bool? = nil, agent: String? = nil, record: String? = nil
        ) {
            self.params = params
            self.auth = auth
            self.verifyTLS = verifyTLS
            self.followRedirects = followRedirects
            self.captureAsSecret = captureAsSecret
            self.agent = agent
            self.record = record
            self.method = method
            self.url = url
            self.headers = headers
            self.body = body
            self.environment = environment
            self.variables = variables
            self.captures = captures
            self.bodyCap = bodyCap
            self.dryRun = dryRun
        }
    }

    /// Any non-2xx reply. The CLI prints `error` and nothing else.
    public struct Failure: Codable, Sendable {
        public var error: String
        /// What the tool should exit with, so a path that does not exist is 2 and a bad flag
        /// value is 1 whether the workspace was read locally or by the app. Nil from an older app.
        public var exitCode: Int32?
        public init(error: String, exitCode: Int32? = nil) {
            self.error = error
            self.exitCode = exitCode
        }
    }
}
