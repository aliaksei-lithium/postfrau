import Foundation

/// Parses `Set-Cookie` header values.
///
/// Deliberately hand-written rather than delegating to `HTTPCookie`: the viewer should show what
/// the server actually sent, including attributes `HTTPCookie` discards and cookies it rejects.
public enum CookieParser {
    public static func parse(setCookie header: String) -> ResponseCookie? {
        // `name=value; Attr; Attr=Value` — the first pair is the cookie itself.
        let parts = header.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let equals = first.firstIndex(of: "=") else { return nil }

        let name = String(first[first.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var cookie = ResponseCookie(
            name: name,
            value: String(first[first.index(after: equals)...]).trimmingCharacters(in: .whitespaces))

        for attribute in parts.dropFirst() {
            let (key, value) = splitAttribute(attribute)
            switch key.lowercased() {
            case "domain": cookie.domain = value
            case "path": cookie.path = value
            case "expires": cookie.expires = value
            case "max-age": cookie.maxAge = value.flatMap(Int.init)
            case "secure": cookie.isSecure = true
            case "httponly": cookie.isHTTPOnly = true
            case "samesite": cookie.sameSite = value
            default: break
            }
        }
        return cookie
    }

    /// Every cookie in a response's headers, in the order the server sent them.
    public static func parse(headers: [HeaderField]) -> [ResponseCookie] {
        headers
            .filter { $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame }
            .compactMap { parse(setCookie: $0.value) }
    }

    private static func splitAttribute(_ text: String) -> (key: String, value: String?) {
        guard let equals = text.firstIndex(of: "=") else {
            return (text.trimmingCharacters(in: .whitespaces), nil)
        }
        return (
            String(text[text.startIndex..<equals]).trimmingCharacters(in: .whitespaces),
            String(text[text.index(after: equals)...]).trimmingCharacters(in: .whitespaces))
    }
}
