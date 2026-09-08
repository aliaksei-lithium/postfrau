import SwiftUI
import PostfrauCore

/// Settings ▸ Advanced: the command line tool, and the escape hatches.
struct AdvancedSettings: View {
    @Environment(AppState.self) private var state

    @State private var installMessage: String?
    @State private var installFailed = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    if let path = CommandLineTool.installedPath {
                        Label(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                              systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Not installed").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Install Command Line Tool…") { install() }
                        .disabled(CommandLineTool.bundledBinary == nil)
                    if CommandLineTool.installedPath != nil {
                        Button("Remove") { remove() }
                    }
                    Spacer()
                }
                if let installMessage {
                    Text(installMessage)
                        .font(.callout)
                        .foregroundStyle(installFailed ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Command line")
            } footer: {
                Text(
                    "`postfrau` does everything this app does, from a shell — for scripts and "
                        + "for agents. It shares this workspace and writes to the same history. "
                        + "Postfrau links it into a folder you choose; it never asks for an "
                        + "administrator password.")
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Files") {
                Button("Open Local State Folder") {
                    Task { FileDialogs.reveal(await state.store.localStateRoot) }
                }
                Button("Reinstall the Sample Collection") {
                    Task { await state.installSampleCollection() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func install() {
        // /usr/local/bin needs a password on a stock Mac, and asking for one to install a
        // convenience is not a trade worth making. The panel lets the user pick somewhere they
        // can already write — ~/.local/bin, /opt/homebrew/bin — and remembers nothing else.
        guard let source = CommandLineTool.bundledBinary else { return }
        let suggested = CommandLineTool.likelyDestinations.first
        guard let directory = FileDialogs.chooseFolder(
            prompt: "Install Here",
            message: "Choose a folder on your PATH. ~/.local/bin and /opt/homebrew/bin are "
                + "the usual choices; /usr/local/bin needs an administrator password, which "
                + "Postfrau will not ask for.",
            startingAt: suggested)
        else { return }

        do {
            let path = try CommandLineTool.link(source, into: directory)
            installFailed = false
            installMessage = "Linked \(path). "
                + (CommandLineTool.isOnPath(directory)
                   ? "Run `postfrau help` to check it."
                   : "That folder is not on your PATH yet — add it to your shell profile.")
        } catch {
            installFailed = true
            installMessage = AppState.message(for: error)
        }
    }

    private func remove() {
        do {
            try CommandLineTool.unlink()
            installFailed = false
            installMessage = "Removed."
        } catch {
            installFailed = true
            installMessage = AppState.message(for: error)
        }
    }
}

/// Finding, linking and unlinking the `postfrau` binary that ships inside the app.
enum CommandLineTool {
    /// `Postfrau.app/Contents/Helpers/postfrau`.
    ///
    /// Not `Contents/MacOS`: macOS filesystems are case-insensitive, so a file called `postfrau`
    /// beside the app's own `Postfrau` executable would overwrite it.
    static var bundledBinary: URL? {
        let url = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/postfrau", directoryHint: .notDirectory)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static let likelyDestinations: [URL] = {
        ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }()

    /// Where a `postfrau` that resolves to this app already sits, if anywhere.
    static var installedPath: String? {
        let candidates = likelyDestinations + [URL(filePath: "/usr/local/bin", directoryHint: .isDirectory)]
        for directory in candidates {
            let link = directory.appending(path: "postfrau", directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: link.path) else { continue }
            return link.path
        }
        return nil
    }

    enum InstallError: Error, LocalizedError {
        case notWritable(String)

        var errorDescription: String? {
            switch self {
            case .notWritable(let path):
                "Postfrau cannot write to \(path). Choose a folder you own, such as "
                    + "~/.local/bin, and add it to your PATH."
            }
        }
    }

    @discardableResult
    static func link(_ source: URL, into directory: URL) throws -> String {
        let destination = directory.appending(path: "postfrau", directoryHint: .notDirectory)
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw InstallError.notWritable(directory.path)
        }
        // A symlink rather than a copy, so the tool follows the app when it updates.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        return destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    static func unlink() throws {
        guard let path = installedPath else { return }
        try FileManager.default.removeItem(at: URL(filePath: path))
    }

    static func isOnPath(_ directory: URL) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { $0 == directory.path }
    }
}
