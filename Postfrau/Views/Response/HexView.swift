import SwiftUI
import PostfrauCore

/// A hex dump for responses that are not text.
///
/// Only the first slice is rendered: nobody reads megabytes of hex, and the point is to let
/// someone confirm what they received (a PNG header, a gzip magic number) before saving it.
struct HexView: View {
    var responseBody: ResponseBody
    var fontSize: Double
    var onSave: () -> Void

    nonisolated static let previewBytes = 4096

    @State private var bytes: Data?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.gearshape")
                Text("This response is not text.")
                Button("Save to File…", action: onSave)
                    .buttonStyle(.borderless)
                Spacer()
                if let bytes, responseBody.byteCount > bytes.count {
                    Text("first \(ByteCount.format(bytes.count)) of \(ByteCount.format(responseBody.byteCount))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary)

            if isLoading {
                CenteredMessage(symbol: "hourglass", title: "Reading…", message: "")
            } else if let bytes {
                ScrollView {
                    Text(Self.dump(bytes))
                        .font(.system(size: fontSize, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .accessibilityLabel("Hex dump of the response")
            }
        }
        .task(id: responseBody.byteCount) {
            isLoading = true
            bytes = await Self.read(responseBody)
            isLoading = false
        }
    }

    @concurrent
    private static func read(_ body: ResponseBody) async -> Data {
        (try? body.prefix(previewBytes)) ?? Data()
    }

    /// `00000000  89 50 4e 47 0d 0a 1a 0a  00 00 00 0d 49 48 44 52  |.PNG........IHDR|`
    static func dump(_ data: Data) -> String {
        var out = ""
        out.reserveCapacity(data.count * 4)
        let bytes = [UInt8](data)

        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            out += String(format: "%08x  ", offset)

            for column in 0..<16 {
                if column < row.count {
                    out += String(format: "%02x ", row[row.startIndex + column])
                } else {
                    out += "   "
                }
                if column == 7 { out += " " }
            }

            out += " |"
            for byte in row {
                out.append(byte >= 0x20 && byte < 0x7F ? Character(UnicodeScalar(byte)) : ".")
            }
            out += "|\n"
        }
        return out
    }
}
