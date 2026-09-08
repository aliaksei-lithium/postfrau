import Foundation
import PostfrauCore

/// Finding the same data the app is using.
///
/// The CLI is a separate process from a sandboxed app, so it cannot inherit the app's
/// security-scoped bookmark. It finds the folder the way a person would explain it: what you told
/// me, else what the environment says, else what the app wrote down, else the default.
enum Configuration {
    /// `~/Library/Containers/com.postfrau.Postfrau/Data/Library/Application Support/Postfrau`
    ///
    /// Where a sandboxed Postfrau keeps its machine-local state. The CLI is not itself sandboxed,
    /// so it can read this directly — which is what lets `postfrau` and the app share history and
    /// settings without any coordination beyond the filesystem.
    static var appContainerLocalRoot: URL {
        URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Containers/com.postfrau.Postfrau/Data", directoryHint: .isDirectory)
            .appending(path: "Library/Application Support/Postfrau", directoryHint: .isDirectory)
    }

    struct Resolved {
        var dataFolder: DataFolder
        var localRoot: URL
        var settings: AppSettings
        /// How the folder was chosen, for `postfrau version` and error messages.
        var origin: String
    }

    /// - Parameters:
    ///   - dataDirectory: the `--data-dir` flag.
    static func resolve(dataDirectory: String?) -> Resolved {
        let environment = ProcessInfo.processInfo.environment

        let localRoot = environment["POSTFRAU_LOCAL_ROOT"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        } ?? appContainerLocalRoot

        let settings = loadSettings(localRoot: localRoot)

        if let dataDirectory {
            return Resolved(
                dataFolder: folder(at: dataDirectory), localRoot: localRoot,
                settings: settings, origin: "--data-dir")
        }
        if let fromEnvironment = environment["POSTFRAU_DATA_DIR"], !fromEnvironment.isEmpty {
            return Resolved(
                dataFolder: folder(at: fromEnvironment), localRoot: localRoot,
                settings: settings, origin: "POSTFRAU_DATA_DIR")
        }
        if let path = settings.dataFolderPath, !path.isEmpty {
            return Resolved(
                dataFolder: folder(at: path), localRoot: localRoot,
                settings: settings, origin: "the app's settings")
        }
        return Resolved(
            dataFolder: DataFolder.defaultFolder(localRoot: localRoot).refreshingStatus(),
            localRoot: localRoot, settings: settings, origin: "the default location")
    }

    private static func folder(at path: String) -> DataFolder {
        DataFolder(
            root: URL(filePath: path, directoryHint: .isDirectory),
            isDefault: false,
            // Another process — the app — may be writing here at the same time.
            needsCoordination: true)
        .refreshingStatus()
    }

    /// Reads `settings.json` directly rather than through the store, because the store needs a
    /// data folder and the data folder is what this is trying to work out.
    private static func loadSettings(localRoot: URL) -> AppSettings {
        let url = localRoot.appending(path: "settings.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url),
              let settings = try? Postfrau.makeDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    /// Builds the runner every command uses.
    static func makeRunner(
        _ resolved: Resolved, source: HistorySource, recordLevel: HistoryRecordLevel?
    ) -> CommandRunner {
        CommandRunner(
            store: WorkspaceStore(dataFolder: resolved.dataFolder, localRoot: resolved.localRoot),
            history: HistoryStore(
                root: resolved.localRoot.appending(path: "history", directoryHint: .isDirectory),
                maxEntries: resolved.settings.maxHistoryEntries),
            source: source,
            recordLevel: recordLevel)
    }

    /// Who a send is attributed to: `--as`, else `POSTFRAU_AGENT`, else the plain CLI.
    static func source(from flag: String?) -> HistorySource {
        let name = flag ?? ProcessInfo.processInfo.environment["POSTFRAU_AGENT"]
        guard let name, !name.isEmpty else { return .cli }
        return .agent(name: name)
    }

    /// A secret the Keychain would not give up can be supplied as `POSTFRAU_SECRET_<KEY>`.
    ///
    /// A second binary reading the app's Keychain items raises a one-time "Always Allow" prompt,
    /// which cannot be answered on a machine nobody is sitting at. This is the way out that does
    /// not involve turning the prompt off.
    static func secretOverrides() -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in ProcessInfo.processInfo.environment
        where key.hasPrefix("POSTFRAU_SECRET_") {
            out[String(key.dropFirst("POSTFRAU_SECRET_".count))] = value
        }
        return out
    }
}
