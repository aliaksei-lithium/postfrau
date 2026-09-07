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
        case .pretty:
            ResponseBodyView(response: response, tab: tab, pretty: true)
        case .raw:
            ResponseBodyView(response: response, tab: tab, pretty: false)
        case .preview:
            ResponsePreview(
                response: response,
                content: state.contentKind(for: response),
                allowsJavaScript: state.settings.allowPreviewJavaScript)
        case .headers:
            HeaderTable(title: "Response headers", fields: response.headers)
        case .cookies:
            CookieTable(cookies: response.cookies)
        }
    }
}

/// Status, time, size, redirect count and the view switcher.
struct ResponseHeaderLine: View {
    @Environment(AppState.self) private var state
    var response: HTTPResponse
    @Bindable var tab: RequestTab

    @State private var showingTiming = false
    @State private var showingRedirects = false

    var body: some View {
        HStack(spacing: 12) {
            StatusBadge(statusCode: response.statusCode, reasonPhrase: response.reasonPhrase)

            Button {
                showingTiming = true
            } label: {
                Label(
                    ByteCount.formatDuration(milliseconds: response.timing.totalMilliseconds),
                    systemImage: "clock")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .foregroundStyle(.secondary)
            .help("Show the timing breakdown")
            .accessibilityLabel(
                "Took \(ByteCount.formatDuration(milliseconds: response.timing.totalMilliseconds)). "
                    + "Show the timing breakdown.")
            .popover(isPresented: $showingTiming, arrowEdge: .bottom) {
                TimingPopover(timing: response.timing).frame(width: 320)
            }

            Label(ByteCount.format(response.byteCount), systemImage: "arrow.down.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Response size \(ByteCount.format(response.byteCount))")

            if !response.redirects.isEmpty {
                Button {
                    showingRedirects = true
                } label: {
                    Label("\(response.redirects.count)", systemImage: "arrow.turn.down.right")
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Show the redirect chain")
                .accessibilityLabel("\(response.redirects.count) redirects. Show the chain.")
                .popover(isPresented: $showingRedirects, arrowEdge: .bottom) {
                    RedirectChainView(redirects: response.redirects, finalURL: response.finalURL)
                        .frame(width: 420)
                }
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

            ResponseActionsMenu(response: response, tab: tab)
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

/// Copy, save, wrap and line numbers — the things that do not deserve a permanent button.
struct ResponseActionsMenu: View {
    @Environment(AppState.self) private var state
    var response: HTTPResponse
    var tab: RequestTab

    var body: some View {
        @Bindable var state = state
        Menu {
            Button("Find…") { tab.findRequests += 1 }
            Divider()
            Button("Copy Body") { copyBody() }
            Button("Save Body…") { saveBody() }
            Divider()
            Toggle("Wrap Lines", isOn: Binding(
                get: { state.settings.wrapResponseLines },
                set: { state.settings.wrapResponseLines = $0; state.markSettingsDirty() }))
            Toggle("Line Numbers", isOn: Binding(
                get: { state.settings.showResponseLineNumbers },
                set: { state.settings.showResponseLineNumbers = $0; state.markSettingsDirty() }))
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("Response actions")
    }

    private func copyBody() {
        Task {
            guard let data = await state.readBody(response) else { return }
            Pasteboard.copy(String(decoding: data, as: UTF8.self))
        }
    }

    private func saveBody() {
        Task {
            guard let data = await state.readBody(response) else { return }
            FileDialogs.save(data, suggestedName: state.suggestedFilename(for: response))
        }
    }
}

/// Where the time went.
struct TimingPopover: View {
    var timing: Timing

    var body: some View {
        let phases = timing.breakdown
        let total = max(phases.reduce(0) { $0 + $1.seconds }, 0.0001)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Timing").font(.headline)
                Spacer()
                Text(ByteCount.formatDuration(milliseconds: timing.totalMilliseconds))
                    .font(.headline.monospacedDigit())
            }

            if phases.isEmpty {
                Text("No breakdown available — the connection was reused or served from cache.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(phases, id: \.label) { phase in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(phase.label).font(.callout)
                            Spacer()
                            Text(ByteCount.formatDuration(milliseconds: phase.seconds * 1000))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor)
                                .frame(width: max(2, proxy.size.width * phase.seconds / total))
                        }
                        .frame(height: 4)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(phase.label): \(ByteCount.formatDuration(milliseconds: phase.seconds * 1000))")
                }
            }
        }
        .padding(14)
    }
}

/// Every hop a request took before it landed.
struct RedirectChainView: View {
    var redirects: [RedirectHop]
    var finalURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Redirects").font(.headline)
            ForEach(Array(redirects.enumerated()), id: \.offset) { index, hop in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(hop.statusCode)")
                        .font(.callout.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hop.url)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Label(hop.location, systemImage: "arrow.turn.down.right")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Hop \(index + 1): \(hop.statusCode) to \(hop.location)")
            }
            Divider()
            Text(finalURL)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .padding(14)
    }
}
