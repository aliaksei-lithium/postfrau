import Foundation
import PostfrauCore

/// Writing to the terminal, or to whatever the output was piped into.
///
/// Two audiences with different needs: a person reading a table, and a program (or an agent)
/// reading `--json`. Colour is only ever used when stdout is a terminal, so a redirect never gets
/// escape codes in it.
struct Output: Sendable {
    var isJSON: Bool
    var isQuiet: Bool
    /// True when secret values may be printed. Off unless `--reveal` was given.
    var reveals: Bool

    /// Colour is a terminal affordance; a pipe gets plain text.
    let isTTY = isatty(STDOUT_FILENO) == 1

    init(isJSON: Bool = false, isQuiet: Bool = false, reveals: Bool = false) {
        self.isJSON = isJSON
        self.isQuiet = isQuiet
        self.reveals = reveals
    }

    // MARK: - Writing

    func print(_ text: String) {
        guard !isQuiet else { return }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    /// Always written, even under `--quiet`: a program that asked for JSON is asking for the
    /// answer, not for chatter.
    func emit(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    func error(_ text: String) {
        FileHandle.standardError.write(Data(("postfrau: " + text + "\n").utf8))
    }

    func warning(_ text: String) {
        guard !isQuiet, !isJSON else { return }
        FileHandle.standardError.write(Data((dim("warning: " + text) + "\n").utf8))
    }

    // MARK: - JSON

    func json(_ value: some Encodable) {
        guard let data = try? Postfrau.makeEncoder(pretty: true).encode(value) else {
            error("could not encode the result as JSON")
            return
        }
        emit(String(decoding: data, as: UTF8.self))
    }

    /// One object per line, for `run --all`: a consumer can act on each result as it lands
    /// instead of waiting for the whole folder.
    func ndjson(_ value: some Encodable) {
        guard let data = try? Postfrau.makeEncoder(pretty: false).encode(value) else { return }
        emit(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Tables

    /// Columns padded to their widest cell. Padding is by display width, not character count, so
    /// a name with an accent still lines up.
    func table(_ rows: [[String]], separator: String = "  ") {
        guard !rows.isEmpty else { return }
        let columnCount = rows.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columnCount)
        for row in rows {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], Self.displayWidth(cell))
            }
        }
        for row in rows {
            var line = ""
            for (index, cell) in row.enumerated() {
                let isLast = index == row.count - 1
                line += cell
                if !isLast {
                    line += String(repeating: " ", count: widths[index] - Self.displayWidth(cell))
                    line += separator
                }
            }
            print(line.replacingOccurrences(
                of: "\\s+$", with: "", options: .regularExpression))
        }
    }

    /// The width a string occupies, ignoring the escape codes colour adds.
    static func displayWidth(_ text: String) -> Int {
        var width = 0
        var inEscape = false
        for character in text {
            if inEscape {
                if character == "m" { inEscape = false }
                continue
            }
            if character == "\u{1B}" { inEscape = true; continue }
            width += 1
        }
        return width
    }

    // MARK: - Colour

    func method(_ name: String) -> String {
        guard isTTY else { return name }
        return switch name.uppercased() {
        case "GET": green(name)
        case "POST": yellow(name)
        case "PUT", "PATCH": magenta(name)
        case "DELETE": red(name)
        default: name
        }
    }

    func status(_ code: Int?) -> String {
        guard let code else { return isTTY ? red("failed") : "failed" }
        let text = "\(code)"
        guard isTTY else { return text }
        return code < 300 ? green(text) : (code < 400 ? yellow(text) : red(text))
    }

    func bold(_ text: String) -> String { isTTY ? "\u{1B}[1m\(text)\u{1B}[0m" : text }
    func dim(_ text: String) -> String { isTTY ? "\u{1B}[2m\(text)\u{1B}[0m" : text }
    func red(_ text: String) -> String { isTTY ? "\u{1B}[31m\(text)\u{1B}[0m" : text }
    func green(_ text: String) -> String { isTTY ? "\u{1B}[32m\(text)\u{1B}[0m" : text }
    func yellow(_ text: String) -> String { isTTY ? "\u{1B}[33m\(text)\u{1B}[0m" : text }
    func magenta(_ text: String) -> String { isTTY ? "\u{1B}[35m\(text)\u{1B}[0m" : text }

    /// A secret value, unless `--reveal` said otherwise.
    func secret(_ value: String) -> String {
        reveals ? value : HistoryRedactor.placeholder
    }
}
