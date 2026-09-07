import SwiftUI
import PostfrauCore

/// The bottom half of the detail pane.
struct ResponsePane: View {
    @Environment(AppState.self) private var state
    @Bindable var tab: RequestTab

    var body: some View {
        VStack(spacing: 0) {
            if let response = tab.response {
                ResponseHeaderLine(response: response, tab: tab)
                Divider()
                content(for: response)
            } else if let message = tab.errorMessage {
                ErrorCard(message: message) { state.send(tab) }
            } else if tab.isSending {
                CenteredMessage(
                    symbol: "arrow.up.arrow.down.circle", title: "Sending…",
                    message: "Press Esc to cancel.")
            } else {
                CenteredMessage(
                    symbol: "paperplane", title: "No response yet",
                    message: "Press ⌘↩ to send this request.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    @ViewBuilder
    private func content(for response: HTTPResponse) -> some View {
        switch tab.selectedResponseTab {
        case .pretty, .raw, .preview:
            // Pretty-printing, highlighting and the HTML preview arrive in Phase 5.
            ResponseBodyView(response: response, fontSize: state.settings.editorFontSize)
        case .headers:
            HeaderTable(title: "Response headers", fields: response.headers)
        case .cookies:
            CookieTable(cookies: response.cookies)
        }
    }
}

/// Status, time, size and the view switcher.
struct ResponseHeaderLine: View {
    var response: HTTPResponse
    @Bindable var tab: RequestTab

    var body: some View {
        HStack(spacing: 14) {
            StatusBadge(statusCode: response.statusCode, reasonPhrase: response.reasonPhrase)

            Label(
                ByteCount.formatDuration(milliseconds: response.timing.totalMilliseconds),
                systemImage: "clock")
            .labelStyle(.titleAndIcon)
            .font(.callout)
            .foregroundStyle(.secondary)

            Label(ByteCount.format(response.byteCount), systemImage: "arrow.down.circle")
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(.secondary)

            if !response.redirects.isEmpty {
                Label("\(response.redirects.count)", systemImage: "arrow.turn.down.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(response.redirects.map(\.location).joined(separator: "\n"))
            }

            Spacer(minLength: 8)

            Picker("Response view", selection: $tab.selectedResponseTab) {
                ForEach(ResponseTab.allCases) { responseTab in
                    Text(title(for: responseTab)).tag(responseTab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func title(for responseTab: ResponseTab) -> String {
        switch responseTab {
        case .headers: "Headers (\(response.headers.count))"
        case .cookies: response.cookies.isEmpty ? "Cookies" : "Cookies (\(response.cookies.count))"
        default: responseTab.title
        }
    }
}

/// The body itself. Reads the bytes off the main thread and shows a bounded window of a huge one.
struct ResponseBodyView: View {
    var response: HTTPResponse
    var fontSize: Double

    /// Beyond this, only the first slice is shown until the user asks for the rest.
    static let previewLimit = 1 * 1024 * 1024

    @State private var text = ""
    @State private var isLoading = true
    @State private var isTruncated = false
    @State private var showingFullBody = false

    var body: some View {
        VStack(spacing: 0) {
            if isTruncated && !showingFullBody {
                TruncationBanner(byteCount: response.byteCount) {
                    showingFullBody = true
                }
            }
            if isLoading {
                CenteredMessage(symbol: "hourglass", title: "Reading response…", message: "")
            } else {
                CodeTextView(
                    text: .constant(text), isEditable: false, fontSize: fontSize,
                    wrapsLines: false, accessibilityLabel: "Response body")
            }
        }
        .task(id: taskKey) { await loadBody() }
    }

    private var taskKey: String {
        "\(response.finalURL)-\(response.byteCount)-\(showingFullBody)"
    }

    private func loadBody() async {
        isLoading = true
        let body = response.body
        let encoding = response.textEncodingName
        let limit = showingFullBody ? Int.max : Self.previewLimit

        // Reading (and possibly decoding tens of megabytes) must not touch the main thread.
        let decoded = await Self.decode(body: body, encodingName: encoding, limit: limit)
        text = decoded.text
        isTruncated = decoded.truncated
        isLoading = false
    }

    /// Runs off the main actor. `ResponseBody` is `Sendable` and read-only here.
    @concurrent
    private static func decode(
        body: ResponseBody, encodingName: String?, limit: Int
    ) async -> (text: String, truncated: Bool) {
        let data = (try? (limit == .max ? body.data() : body.prefix(limit))) ?? Data()
        let truncated = limit != .max && body.byteCount > limit
        let encoding = encodingName.flatMap {
            let cf = CFStringConvertIANACharSetNameToEncoding($0 as CFString)
            guard cf != kCFStringEncodingInvalidId else { return String.Encoding?.none }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        } ?? .utf8

        if let text = String(data: data, encoding: encoding) { return (text, truncated) }
        if let text = String(data: data, encoding: .isoLatin1) { return (text, truncated) }
        return (String(decoding: data, as: UTF8.self), truncated)
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
                .buttonStyle(.link)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary)
    }
}

struct HeaderTable: View {
    var title: String
    var fields: [HeaderField]

    var body: some View {
        Table(fields, columns: {
            TableColumn("Name") { field in
                Text(field.name).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            TableColumn("Value") { field in
                Text(field.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
        })
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
            Table(cookies, columns: {
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
            })
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
