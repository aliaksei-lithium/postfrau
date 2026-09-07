import PDFKit
import SwiftUI
import WebKit
import PostfrauCore

/// Renders a response the way a browser would: HTML in a `WebView`, images inline, PDFs in PDFKit.
struct ResponsePreview: View {
    var response: HTTPResponse
    var content: ContentKind
    var allowsJavaScript: Bool

    @State private var payload: Data?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                CenteredMessage(symbol: "hourglass", title: "Loading…", message: "")
            } else if let payload {
                preview(payload)
            } else {
                CenteredMessage(
                    symbol: "eye.slash", title: "Nothing to preview",
                    message: "The response body could not be read.")
            }
        }
        .task(id: response.finalURL + String(response.byteCount)) { await load() }
    }

    @ViewBuilder
    private func preview(_ data: Data) -> some View {
        switch content {
        case .html:
            HTMLPreview(
                html: String(decoding: data, as: UTF8.self),
                baseURL: URL(string: response.finalURL),
                allowsJavaScript: allowsJavaScript)
        case .image:
            if let image = NSImage(data: data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                }
                .accessibilityLabel("Response image, \(Int(image.size.width)) by \(Int(image.size.height)) points")
            } else {
                CenteredMessage(
                    symbol: "photo", title: "Unreadable image",
                    message: "macOS could not decode these bytes as an image.")
            }
        case .pdf:
            PDFPreview(data: data)
        case .json, .xml, .text, .binary:
            CenteredMessage(
                symbol: "eye.slash", title: "No preview",
                message: "Preview shows HTML, images and PDFs. Use Pretty or Raw for this response.")
        }
    }

    /// Reading (and decoding) a large body must not happen on the main thread.
    private func load() async {
        isLoading = true
        // Previewing is only sensible for something a person can look at; a 50 MB HTML file is
        // not, and rendering it would stall WebKit.
        let limit = 8 * 1024 * 1024
        payload = await Self.read(response.body, limit: limit)
        isLoading = false
    }

    @concurrent
    private static func read(_ body: ResponseBody, limit: Int) async -> Data? {
        try? body.prefix(limit)
    }
}

/// HTML in a `WebPage`, with the network turned off.
///
/// `loadsSubresources = false` and `allowsContentJavaScript = false` mean a previewed response
/// cannot fetch anything or run anything: looking at a response should never be a way for a server
/// to learn that you looked, or to execute code in your client. The Settings toggle re-enables
/// JavaScript for the cases where a page is genuinely unreadable without it.
struct HTMLPreview: View {
    var html: String
    var baseURL: URL?
    var allowsJavaScript: Bool

    @State private var page = WebPage()

    var body: some View {
        WebView(page)
            .webViewContentBackground(.hidden)
            .accessibilityLabel("Rendered HTML preview")
            .task(id: "\(html.count)-\(allowsJavaScript)") {
                var configuration = WebPage.Configuration()
                configuration.loadsSubresources = false
                configuration.defaultNavigationPreferences.allowsContentJavaScript = allowsJavaScript
                page = WebPage(configuration: configuration)
                _ = page.load(html: html, baseURL: baseURL ?? URL(string: "about:blank")!)
            }
    }
}

struct PDFPreview: NSViewRepresentable {
    var data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.setAccessibilityLabel("Response PDF")
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // Re-creating the document on every update would reset the scroll position.
        if view.document == nil || view.document?.dataRepresentation() != data {
            view.document = PDFDocument(data: data)
        }
    }
}
