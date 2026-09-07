import Foundation

/// One header, kept as a list rather than a dictionary because order matters and duplicates
/// (several `Set-Cookie`, several `Vary`) are legal.
public struct HeaderField: Sendable, Hashable, Codable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

extension [HeaderField] {
    /// Case-insensitive lookup; joins duplicates the way HTTP does.
    public func value(for name: String) -> String? {
        let matches = filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard !matches.isEmpty else { return nil }
        return matches.map(\.value).joined(separator: ", ")
    }

    public func contains(name: String) -> Bool {
        contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Where a response body ended up. Large bodies spill to a temporary file rather than to memory.
public enum ResponseBody: Sendable {
    case inMemory(Data)
    case onDisk(URL, byteCount: Int)

    public var byteCount: Int {
        switch self {
        case .inMemory(let data): data.count
        case .onDisk(_, let count): count
        }
    }

    public var isOnDisk: Bool {
        if case .onDisk = self { return true }
        return false
    }

    /// Reads the whole body. For an on-disk body this is a real read, so keep it off the main thread.
    public func data() throws -> Data {
        switch self {
        case .inMemory(let data): data
        case .onDisk(let url, _): try Data(contentsOf: url)
        }
    }

    /// Reads at most `limit` bytes — what the viewer uses for a huge body.
    public func prefix(_ limit: Int) throws -> Data {
        switch self {
        case .inMemory(let data):
            return data.prefix(limit)
        case .onDisk(let url, _):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: limit) ?? Data()
        }
    }

    /// Removes the spill file, if there is one. Called when a response is discarded.
    public func discardTemporaryFile() {
        if case .onDisk(let url, _) = self {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Where the time went, from `URLSessionTaskMetrics`. Any phase can be nil: a reused connection
/// has no DNS or TLS time, and a cached response has almost none of it.
public struct Timing: Sendable, Hashable {
    public var total: TimeInterval
    public var dns: TimeInterval?
    public var connect: TimeInterval?
    public var tls: TimeInterval?
    public var request: TimeInterval?
    /// Time to first byte, measured from the start of the request.
    public var ttfb: TimeInterval?
    public var download: TimeInterval?

    public init(
        total: TimeInterval = 0,
        dns: TimeInterval? = nil,
        connect: TimeInterval? = nil,
        tls: TimeInterval? = nil,
        request: TimeInterval? = nil,
        ttfb: TimeInterval? = nil,
        download: TimeInterval? = nil
    ) {
        self.total = total
        self.dns = dns
        self.connect = connect
        self.tls = tls
        self.request = request
        self.ttfb = ttfb
        self.download = download
    }

    public var totalMilliseconds: Double { total * 1000 }

    /// The phases that were actually measured, for the timing popover's bar chart.
    public var breakdown: [(label: String, seconds: TimeInterval)] {
        var out: [(String, TimeInterval)] = []
        if let dns { out.append(("DNS", dns)) }
        if let connect { out.append(("Connect", connect)) }
        if let tls { out.append(("TLS", tls)) }
        if let request { out.append(("Request", request)) }
        if let ttfb { out.append(("Waiting", ttfb)) }
        if let download { out.append(("Download", download)) }
        return out
    }
}

/// One step of a redirect chain.
public struct RedirectHop: Sendable, Hashable {
    public var statusCode: Int
    public var url: String
    public var location: String

    public init(statusCode: Int, url: String, location: String) {
        self.statusCode = statusCode
        self.url = url
        self.location = location
    }
}

/// A cookie parsed out of a `Set-Cookie` header.
///
/// Parsed by hand rather than through `HTTPCookie` so the viewer can show exactly what the server
/// sent, including attributes `HTTPCookie` drops and cookies it would reject.
public struct ResponseCookie: Sendable, Hashable {
    public var name: String
    public var value: String
    public var domain: String?
    public var path: String?
    public var expires: String?
    public var maxAge: Int?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var sameSite: String?

    public init(
        name: String, value: String, domain: String? = nil, path: String? = nil,
        expires: String? = nil, maxAge: Int? = nil, isSecure: Bool = false,
        isHTTPOnly: Bool = false, sameSite: String? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.maxAge = maxAge
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
    }
}

/// Everything Postfrau knows about one completed exchange.
public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var reasonPhrase: String
    public var headers: [HeaderField]
    public var body: ResponseBody
    public var mimeType: String?
    public var textEncodingName: String?
    public var timing: Timing
    public var redirects: [RedirectHop]
    public var finalURL: String
    public var cookies: [ResponseCookie]
    /// The headers Postfrau actually put on the wire, including the ones it added itself.
    public var sentHeaders: [HeaderField]
    /// True when the body was cut short by the 200 MB hard cap.
    public var wasTruncated: Bool

    public init(
        statusCode: Int,
        reasonPhrase: String,
        headers: [HeaderField],
        body: ResponseBody,
        mimeType: String? = nil,
        textEncodingName: String? = nil,
        timing: Timing = Timing(),
        redirects: [RedirectHop] = [],
        finalURL: String = "",
        cookies: [ResponseCookie] = [],
        sentHeaders: [HeaderField] = [],
        wasTruncated: Bool = false
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
        self.mimeType = mimeType
        self.textEncodingName = textEncodingName
        self.timing = timing
        self.redirects = redirects
        self.finalURL = finalURL
        self.cookies = cookies
        self.sentHeaders = sentHeaders
        self.wasTruncated = wasTruncated
    }

    public var byteCount: Int { body.byteCount }

    /// `2xx` and `3xx` are treated as success for the status pill's colour.
    public var isSuccess: Bool { (200..<400).contains(statusCode) }

    public var statusLine: String { "\(statusCode) \(reasonPhrase)" }
}
