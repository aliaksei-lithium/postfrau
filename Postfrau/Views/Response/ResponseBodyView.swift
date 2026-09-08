import SwiftUI
import PostfrauCore

/// The response body, pretty-printed and syntax-highlighted, or raw.
///
/// Everything expensive — reading the bytes off disk, decoding them, re-indenting, tokenizing —
/// happens off the main actor, and the view shows the plain text as soon as it has it rather than
/// waiting for highlighting. A body too large to render in full shows its first slice with a
/// button to load the rest.
struct ResponseBodyView: View {
    @Environment(AppState.self) private var state
    var response: HTTPResponse
    var tab: RequestTab
    var pretty: Bool

    /// Bodies at or below this are rendered whole (§5).
    static let renderWholeBelow = 5 * 1024 * 1024
    /// Above that, only this much is rendered until the user asks for the rest.
    static let previewLimit = 1 * 1024 * 1024

    @State private var text = ""
    @State private var tokens: [SyntaxToken] = []
    @State private var isLoading = true
    @State private var isTruncated = false
    @State private var showingFullBody = false
    @State private var prettyFailure: String?

    var body: some View {
        let content = state.contentKind(for: response)

        Group {
            if !content.isTextual {
                HexView(
                    responseBody: response.body,
                    fontSize: state.settings.editorFontSize,
                    onSave: saveBody)
            } else {
                VStack(spacing: 0) {
                    if isTruncated && !showingFullBody {
                        TruncationBanner(byteCount: response.byteCount) { showingFullBody = true }
                    }
                    if let prettyFailure {
                        NoticeBanner(
                            symbol: "text.alignleft",
                            message: "Showing the raw body — \(prettyFailure)")
                    }
                    if isLoading {
                        CenteredMessage(symbol: "hourglass", title: "Reading response…", message: "")
                    } else {
                        CodeTextView(
                            text: .constant(text),
                            isEditable: false,
                            fontSize: state.settings.editorFontSize,
                            wrapsLines: state.settings.wrapResponseLines,
                            showsLineNumbers: state.settings.showResponseLineNumbers,
                            tokens: tokens,
                            findTrigger: tab.findRequests,
                            accessibilityLabel: "Response body")
                    }
                }
            }
        }
        .task(id: taskKey) { await load(content: content) }
    }

    private var taskKey: String {
        "\(tab.id)|\(tab.responseGeneration)|\(pretty)|\(showingFullBody)"
    }

    private func load(content: ContentKind) async {
        guard content.isTextual else { return }

        // The same response rendered the same way gives the same result, so switching back to a
        // tab already seen costs a dictionary lookup rather than a re-read and a re-tokenize.
        if let cached = state.renderedBody(for: taskKey) {
            text = cached.text
            tokens = cached.tokens
            isTruncated = cached.truncated
            prettyFailure = cached.prettyFailure
            isLoading = false
            return
        }

        isLoading = true
        prettyFailure = nil

        let limit = showingFullBody || response.byteCount <= Self.renderWholeBelow
            ? Int.max : Self.previewLimit
        let prepared = await Self.prepare(
            body: response.body,
            encodingName: response.textEncodingName,
            content: content,
            pretty: pretty,
            limit: limit)

        text = prepared.text
        isTruncated = prepared.truncated
        prettyFailure = prepared.prettyFailure
        // Show the text first; highlighting a large body can take a moment longer.
        tokens = []
        isLoading = false

        let snapshot = prepared.text
        let computed = await Self.highlight(snapshot, content: content)
        // Guard against a newer load having replaced the text while this one was running.
        guard snapshot == text else { return }
        tokens = computed
        state.cacheRenderedBody(
            AppState.RenderedBody(
                text: prepared.text,
                tokens: computed,
                truncated: prepared.truncated,
                prettyFailure: prepared.prettyFailure),
            for: taskKey)
    }

    /// Reads, decodes and optionally re-indents. Runs off the main actor.
    @concurrent
    private static func prepare(
        body: ResponseBody,
        encodingName: String?,
        content: ContentKind,
        pretty: Bool,
        limit: Int
    ) async -> (text: String, truncated: Bool, prettyFailure: String?) {
        let data = (try? (limit == .max ? body.data() : body.prefix(limit))) ?? Data()
        let truncated = limit != .max && body.byteCount > limit
        let raw = decode(data, encodingName: encodingName)

        guard pretty, content.canPrettyPrint, !truncated else {
            return (raw, truncated, nil)
        }
        do {
            let formatted = switch content {
            case .json: try JSONPrettyPrinter.prettyPrint(raw)
            case .xml, .html: try XMLPrettyPrinter.prettyPrint(raw)
            default: raw
            }
            return (formatted, truncated, nil)
        } catch {
            // A malformed body is common and not an error the user caused; show it raw and say why.
            return (raw, truncated, (error as? any LocalizedError)?.errorDescription
                ?? error.localizedDescription)
        }
    }

    @concurrent
    private static func highlight(_ text: String, content: ContentKind) async -> [SyntaxToken] {
        Highlighters.forContent(content)?.tokens(in: text) ?? []
    }

    /// Honours the charset the server declared, falling back to UTF-8 and then Latin-1 so that
    /// something always renders.
    nonisolated private static func decode(_ data: Data, encodingName: String?) -> String {
        if let name = encodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    private func saveBody() {
        Task {
            guard let data = await state.readBody(response) else { return }
            FileDialogs.save(data, suggestedName: state.suggestedFilename(for: response))
        }
    }
}

struct TruncationBanner: View {
    var byteCount: Int
    var onLoadFull: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
            Text("Showing the first \(ByteCount.format(ResponseBodyView.previewLimit)) "
                + "of \(ByteCount.format(byteCount)).")
            Button("Load Full Response", action: onLoadFull)
                .buttonStyle(.borderless)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary)
        .accessibilityElement(children: .combine)
    }
}

struct NoticeBanner: View {
    var symbol: String
    var message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(message)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary)
        .accessibilityElement(children: .combine)
    }
}

struct HeaderTable: View {
    var title: String
    var fields: [HeaderField]

    var body: some View {
        Table(fields) {
            TableColumn("Name") { field in
                Text(field.name)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            TableColumn("Value") { field in
                Text(field.value)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .accessibilityLabel(title)
    }
}

struct CookieTable: View {
    var cookies: [ResponseCookie]

    var body: some View {
        if cookies.isEmpty {
            CenteredMessage(
                symbol: "birthday.cake", title: "No cookies",
                message: "The server did not send a Set-Cookie header.")
        } else {
            Table(cookies) {
                TableColumn("Name") { Text($0.name).textSelection(.enabled) }
                TableColumn("Value") { Text($0.value).textSelection(.enabled) }
                TableColumn("Domain") { Text($0.domain ?? "—") }
                TableColumn("Path") { Text($0.path ?? "—") }
                TableColumn("Expires") { Text($0.expires ?? "Session") }
                TableColumn("Flags") { cookie in
                    Text([
                        cookie.isSecure ? "Secure" : nil,
                        cookie.isHTTPOnly ? "HttpOnly" : nil,
                        cookie.sameSite.map { "SameSite=\($0)" },
                    ].compactMap { $0 }.joined(separator: ", "))
                }
            }
            .accessibilityLabel("Response cookies")
        }
    }
}

extension ResponseCookie: @retroactive Identifiable {
    public var id: String { "\(name)@\(domain ?? "")\(path ?? "")" }
}

extension HeaderField: @retroactive Identifiable {
    public var id: String { "\(name):\(value)" }
}

struct ErrorCard: View {
    var message: String
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("The request failed").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
            Button("Retry", action: onRetry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request failed: \(message)")
    }
}

struct CenteredMessage: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
