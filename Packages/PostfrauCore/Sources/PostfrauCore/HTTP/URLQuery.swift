import Foundation

/// The two-way bridge between the URL text and the params table.
///
/// `PLAN.md` §3: the URL string owns the scheme/host/path, the params table owns the query.
/// Editing either re-derives the other. Disabled rows stay in the table but never reach the URL,
/// and `{{variables}}` are carried through untouched so a round-trip does not mangle them.
public enum URLQuery {
    /// Splits a URL string into "everything before the query" and its query rows.
    ///
    /// Works on raw text rather than `URLComponents` because the text may contain `{{vars}}` that
    /// make it an invalid URL, and because we must not silently re-encode what the user typed.
    public static func parse(_ url: String) -> (base: String, params: [KeyValue]) {
        // The fragment stays attached to the base so it survives a round-trip.
        guard let questionMark = url.firstIndex(of: "?") else { return (url, []) }
        let base = String(url[url.startIndex..<questionMark])
        let queryText = String(url[url.index(after: questionMark)...])

        var fragment = ""
        var query = queryText
        if let hash = queryText.firstIndex(of: "#") {
            query = String(queryText[queryText.startIndex..<hash])
            fragment = String(queryText[hash...])
        }

        let params = query.isEmpty ? [] : query
            .split(separator: "&", omittingEmptySubsequences: false)
            .map { pair -> KeyValue in
                guard let equals = pair.firstIndex(of: "=") else {
                    return KeyValue(key: decode(String(pair)), value: "")
                }
                return KeyValue(
                    key: decode(String(pair[pair.startIndex..<equals])),
                    value: decode(String(pair[pair.index(after: equals)...])))
            }
        return (base + fragment, params)
    }

    /// Rebuilds a URL string from a base and the params table.
    ///
    /// - Parameter encode: percent-encode keys and values (the request's `encodeURL` setting).
    ///   When false the text is sent exactly as typed, which some APIs need.
    public static func compose(base: String, params: [KeyValue], encode: Bool = true) -> String {
        let (cleanBase, fragment) = splitFragment(stripQuery(from: base))
        let rows = params.filter { $0.enabled && !($0.key.isEmpty && $0.value.isEmpty) }
        guard !rows.isEmpty else { return cleanBase + fragment }

        let query = rows.map { row in
            let key = encode ? self.encode(row.key) : row.key
            let value = encode ? self.encode(row.value) : row.value
            return value.isEmpty && row.value.isEmpty ? key : "\(key)=\(value)"
        }.joined(separator: "&")

        return "\(cleanBase)?\(query)\(fragment)"
    }

    /// Merges freshly typed URL text into an existing params table, keeping row identity (and
    /// therefore the enabled flag and description) for rows whose key is unchanged.
    public static func merge(urlText: String, into existing: [KeyValue]) -> (base: String, params: [KeyValue]) {
        let (base, parsed) = parse(urlText)
        var unusedByKey: [String: [KeyValue]] = [:]
        for row in existing where row.enabled {
            unusedByKey[row.key, default: []].append(row)
        }

        var merged: [KeyValue] = []
        for row in parsed {
            if var reused = unusedByKey[row.key]?.first {
                unusedByKey[row.key]?.removeFirst()
                reused.value = row.value
                merged.append(reused)
            } else {
                merged.append(row)
            }
        }
        // Disabled rows are not in the URL but must survive the edit; keep them at the end.
        merged.append(contentsOf: existing.filter { !$0.enabled })
        return (base, merged)
    }

    /// Everything up to (but excluding) the query.
    public static func stripQuery(from url: String) -> String {
        guard let questionMark = url.firstIndex(of: "?") else { return url }
        let base = String(url[url.startIndex..<questionMark])
        let rest = String(url[url.index(after: questionMark)...])
        if let hash = rest.firstIndex(of: "#") { return base + String(rest[hash...]) }
        return base
    }

    private static func splitFragment(_ url: String) -> (base: String, fragment: String) {
        guard let hash = url.firstIndex(of: "#") else { return (url, "") }
        return (String(url[url.startIndex..<hash]), String(url[hash...]))
    }

    /// Percent-encodes one query component. `{` and `}` are left alone so an unresolved
    /// `{{variable}}` in the editor stays readable; by send time they are already substituted.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: queryComponentAllowed) ?? text
    }

    static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
    }

    /// Unreserved characters plus the sub-delimiters that are safe inside a query component.
    /// Notably excludes `&`, `=`, `+`, `#` and `?`, which would otherwise change the structure.
    private static let queryComponentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~!$'()*,;:@/{}")
        return set
    }()
}
