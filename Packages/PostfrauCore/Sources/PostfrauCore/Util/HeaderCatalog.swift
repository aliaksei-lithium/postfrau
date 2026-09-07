import Foundation

/// Header names offered as autocomplete in the Headers tab.
///
/// Request headers only — there is no point suggesting `Set-Cookie` on something you are sending.
/// Ordered roughly by how often they are typed by hand.
public enum HeaderCatalog {
    public static let requestHeaders = [
        "Accept", "Accept-Encoding", "Accept-Language", "Authorization", "Cache-Control",
        "Content-Type", "Content-Length", "Content-Encoding", "Content-Disposition",
        "Cookie", "Date", "ETag", "Expect", "Forwarded", "From", "Host",
        "If-Match", "If-Modified-Since", "If-None-Match", "If-Unmodified-Since",
        "Idempotency-Key", "Origin", "Pragma", "Prefer", "Proxy-Authorization",
        "Range", "Referer", "TE", "Trailer", "Transfer-Encoding", "Upgrade",
        "User-Agent", "Via", "Warning",
        "X-Api-Key", "X-Correlation-ID", "X-CSRF-Token", "X-Forwarded-For",
        "X-Forwarded-Host", "X-Forwarded-Proto", "X-Request-ID", "X-Requested-With",
    ]

    /// Case-insensitive prefix match, best-first, for a completion menu.
    public static func completions(for prefix: String, limit: Int = 8) -> [String] {
        let needle = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let prefixed = requestHeaders.filter { $0.lowercased().hasPrefix(needle) }
        // Fall back to a contains-match so "type" still finds "Content-Type".
        let contained = requestHeaders.filter {
            !$0.lowercased().hasPrefix(needle) && $0.lowercased().contains(needle)
        }
        return Array((prefixed + contained).prefix(limit))
    }

    /// Value completions for the headers where a fixed vocabulary actually helps.
    public static func valueCompletions(forHeader name: String, prefix: String, limit: Int = 8) -> [String] {
        let candidates: [String]
        switch name.lowercased() {
        case "content-type", "accept":
            candidates = MIMEType.common
        case "cache-control":
            candidates = ["no-cache", "no-store", "max-age=0", "must-revalidate", "public", "private"]
        case "accept-encoding":
            candidates = ["gzip", "deflate", "br", "identity", "gzip, deflate, br"]
        case "connection":
            candidates = ["keep-alive", "close"]
        default:
            return []
        }
        let needle = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return Array(candidates.prefix(limit)) }
        return Array(candidates.filter { $0.lowercased().contains(needle) }.prefix(limit))
    }
}
