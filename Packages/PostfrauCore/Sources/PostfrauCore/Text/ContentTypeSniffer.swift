import Foundation

/// What a response body actually is, once the header and the bytes have both had a say.
public enum ContentKind: Sendable, Hashable {
    case json
    case xml
    case html
    case text
    /// The MIME subtype, e.g. `png`.
    case image(String)
    case pdf
    case binary

    public var isTextual: Bool {
        switch self {
        case .json, .xml, .html, .text: true
        case .image, .pdf, .binary: false
        }
    }

    /// Whether the Pretty tab has anything to offer.
    public var canPrettyPrint: Bool {
        switch self {
        case .json, .xml, .html: true
        default: false
        }
    }
}

/// Decides what a body is.
///
/// The `Content-Type` header is taken first because it is the server's own statement of intent,
/// but plenty of APIs mislabel JSON as `text/plain` or `application/octet-stream`, so the bytes get
/// a look too. A body whose header says nothing useful is classified purely by its first bytes.
public enum ContentTypeSniffer {
    public static func kind(mimeType: String?, bytes: Data) -> ContentKind {
        let mime = (mimeType ?? "")
            .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }?
            .lowercased() ?? ""

        // Unambiguous binary types are believed outright — sniffing them is pointless.
        if mime.hasPrefix("image/") {
            return .image(String(mime.dropFirst("image/".count)))
        }
        if mime == "application/pdf" { return .pdf }
        if mime.hasPrefix("audio/") || mime.hasPrefix("video/") { return .binary }

        if isJSON(mime) { return .json }
        if isXML(mime) { return .xml }
        if isHTML(mime) { return .html }

        // The header was unhelpful; ask the bytes.
        return sniff(bytes)
    }

    /// Classification from the bytes alone.
    public static func sniff(_ bytes: Data) -> ContentKind {
        let head = bytes.prefix(1024)
        guard !head.isEmpty else { return .text }

        if head.starts(with: Data([0x25, 0x50, 0x44, 0x46])) { return .pdf }          // %PDF
        if head.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) { return .image("png") }
        if head.starts(with: Data([0xFF, 0xD8, 0xFF])) { return .image("jpeg") }
        if head.starts(with: Data([0x47, 0x49, 0x46, 0x38])) { return .image("gif") }
        if head.count > 12, head.starts(with: Data([0x52, 0x49, 0x46, 0x46])),        // RIFF
           head[head.startIndex.advanced(by: 8)...].starts(with: Data([0x57, 0x45, 0x42, 0x50])) {
            return .image("webp")
        }

        guard looksLikeText(head) else { return .binary }

        // Skip a BOM and any leading whitespace before judging the first real character.
        var index = head.startIndex
        if head.starts(with: Data([0xEF, 0xBB, 0xBF])) { index = head.index(index, offsetBy: 3) }
        while index < head.endIndex, isWhitespace(head[index]) { index = head.index(after: index) }
        guard index < head.endIndex else { return .text }

        switch head[index] {
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            return .json
        case UInt8(ascii: "<"):
            let text = String(decoding: head[index...].prefix(200), as: UTF8.self).lowercased()
            if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") { return .html }
            return .xml
        default:
            return .text
        }
    }

    private static func isJSON(_ mime: String) -> Bool {
        mime == "application/json" || mime == "text/json"
            || mime.hasSuffix("+json") || mime == "application/problem+json"
    }

    private static func isXML(_ mime: String) -> Bool {
        mime == "application/xml" || mime == "text/xml" || mime.hasSuffix("+xml")
    }

    private static func isHTML(_ mime: String) -> Bool {
        mime == "text/html" || mime == "application/xhtml+xml"
    }

    /// A body is treated as text when its first bytes contain no NULs and decode as UTF-8.
    /// Control characters other than tab/newline/return are the usual giveaway for binary.
    private static func looksLikeText(_ head: Data) -> Bool {
        if head.contains(0x00) { return false }
        let controlCount = head.filter { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }.count
        if controlCount * 20 > head.count { return false }
        return String(data: head, encoding: .utf8) != nil || head.allSatisfy { $0 < 0x80 }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
