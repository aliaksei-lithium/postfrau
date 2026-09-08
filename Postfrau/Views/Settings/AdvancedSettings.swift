import SwiftUI
import PostfrauCore

/// Settings ▸ Advanced: the command line tool, and the escape hatches.
struct AdvancedSettings: View {
    @Environment(AppState.self) private var state

    @State private var installMessage: String?
    @State private var installFailed = false
    /// Where the tool is installed, and whether the bundle carries one.
    ///
    /// Held in state rather than asked of the filesystem inside `body`: every toggle elsewhere in
    /// this window re-evaluates it, and four `stat` calls per redraw is four too many.
    @State private var installedPath: String?
    @State private var hasBundledTool = false
    /// Whether the token is on screen. Off by default: it is a credential, and Settings gets
    /// screen-shared and screenshotted like any other window.
    @State private var showsToken = false
    @State private var copied = false

    /// The two lines someone pastes into a shell or an agent's environment.
    private var shellExport: String {
        """
        export \(LocalAPI.tokenVariable)=\(state.settings.localAPIToken)
        export \(LocalAPI.urlVariable)=\(LocalAPI.defaultURL(port: state.settings.localAPIPort))
        """
    }

    private func copyExport() {
        Pasteboard.copy(shellExport)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    if let path = installedPath {
                        Label(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                              systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Not installed").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Install Command Line Tool…") { install() }
                        .disabled(!hasBundledTool)
                    if installedPath != nil {
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

            Section {
                Toggle("Answer the postfrau CLI over localhost", isOn: Binding(
                    get: { state.settings.localAPIEnabled },
                    set: { enabled in
                        // A token is minted the first time it is switched on, not at launch, so a
                        // workspace that never uses this never stores a credential.
                        if enabled && state.settings.localAPIToken.isEmpty {
                            state.settings.localAPIToken = LocalAPI.makeToken()
                        }
                        state.settings.localAPIEnabled = enabled
                        state.markSettingsDirty()
                    }))

                if state.settings.localAPIEnabled {
                    LabeledContent("Port") {
                        TextField("Port", value: Binding(
                            get: { state.settings.localAPIPort },
                            set: { state.settings.localAPIPort = $0; state.markSettingsDirty() }),
                            format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Token") {
                        HStack(spacing: 8) {
                            Text(showsToken ? state.settings.localAPIToken : "••••••••••••••••")
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button(showsToken ? "Hide" : "Show") { showsToken.toggle() }
                            Button("New") {
                                state.settings.localAPIToken = LocalAPI.makeToken()
                                state.markSettingsDirty()
                            }
                            .help("Mint a new token. Anything using the old one stops working.")
                        }
                    }

                    Button(copied ? "Copied" : "Copy Shell Export") { copyExport() }
                }

                if let error = state.localAPIError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Local API")
            } footer: {
                Text(
                    "For an agent that cannot read your workspace — a sandbox that denies the "
                        + "folder, or this app's container. With the token in its environment, "
                        + "`postfrau ls`, `get`, `run` and `send` ask this app instead of the "
                        + "filesystem, and sends still land in your history. The socket listens "
                        + "on 127.0.0.1 only and refuses anything without the token; it works "
                        + "only while Postfrau is running.")
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
        .task { refreshInstallState() }
    }

    private func refreshInstallState() {
        installedPath = CommandLineTool.installedPath
        hasBundledTool = CommandLineTool.bundledBinary != nil
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
            refreshInstallState()
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
            refreshInstallState()
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
