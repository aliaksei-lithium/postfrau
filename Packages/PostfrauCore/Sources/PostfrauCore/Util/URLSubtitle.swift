import Foundation

/// The short form of a request's URL shown under its name in the sidebar.
///
/// Names alone do not tell rows apart — an imported spec gives forty requests that all start
/// "Provide …" and truncate at the same place. The path does. So the subtitle is the URL without
/// what every row shares: the query string, a leading base variable (`{{baseUrl}}`) and, for a
/// literal URL, the scheme. Path variables stay as written — `/deposits/{{id}}` says more than
/// `/deposits/` would. See `docs/decisions.md` D67.
public enum URLSubtitle {
    public static func text(for url: String) -> String {
        var text = URLQuery.stripQuery(from: url.trimmingCharacters(in: .whitespacesAndNewlines))
        // A fragment says nothing about which endpoint this is.
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }

        if text.hasPrefix("{{"), let close = text.range(of: "}}") {
            let rest = text[close.upperBound...]
            // `{{baseUrl}}/users` → `/users`; a URL that is only a variable keeps it.
            if !rest.isEmpty { text = String(rest) }
        } else if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        }
        return text
    }
}
