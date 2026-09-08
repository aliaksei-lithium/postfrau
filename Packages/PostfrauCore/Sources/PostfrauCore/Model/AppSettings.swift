import Foundation

/// How the request and response panes are stacked.
public enum ResponseLayout: String, Sendable, Hashable, Codable, CaseIterable {
    case vertical
    case horizontal

    public var displayName: String {
        switch self {
        case .vertical: "Response Below"
        case .horizontal: "Response Beside"
        }
    }
}

/// Whether the app follows the system's light/dark setting or overrides it.
public enum Appearance: String, Sendable, Hashable, Codable, CaseIterable {
    case system
    case light
    case dark

    public var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Machine-local preferences. Written to `settings.json` in the local state folder; never synced.
///
/// That is what makes `appearance` work the way people expect: light on the laptop and dark on the
/// work machine, with the same collections folder shared between them.
public struct AppSettings: Sendable, Hashable, Codable {
    /// Security-scoped bookmark to the user's chosen data folder.
    public var dataFolderBookmark: Data?
    /// Last known path of that folder, shown in Settings even when the bookmark is stale.
    public var dataFolderPath: String?
    public var syncSecretsViaICloudKeychain: Bool
    /// Light, dark, or whatever the system is doing.
    public var appearance: Appearance
    public var editorFontSize: Double
    public var responseLayout: ResponseLayout
    public var defaultTimeoutSeconds: Double
    public var defaultVerifyTLS: Bool
    public var maxHistoryEntries: Int
    /// How much of each exchange is written to history.
    public var historyRecording: HistoryRecordLevel
    /// The most bytes of any one body kept in a history entry.
    public var historyBodyCapBytes: Int
    /// Whether the HTML preview may run JavaScript and load subresources. Off by default so a
    /// previewed response cannot phone home.
    public var allowPreviewJavaScript: Bool
    public var wrapResponseLines: Bool
    public var showResponseLineNumbers: Bool
    /// Whether the app answers `postfrau` over a loopback socket. Off until asked for.
    public var localAPIEnabled: Bool
    public var localAPIPort: Int
    /// The bearer token for that socket. Empty until the API is first switched on.
    ///
    /// Kept here, in plain sight, on purpose: this file already sits beside the workspace, so
    /// anything that can read the token could read the collections directly. Putting it in the
    /// Keychain instead would buy nothing and cost the CLI a prompt nobody can answer.
    public var localAPIToken: String

    public init(
        dataFolderBookmark: Data? = nil,
        dataFolderPath: String? = nil,
        syncSecretsViaICloudKeychain: Bool = false,
        appearance: Appearance = .system,
        editorFontSize: Double = 12,
        responseLayout: ResponseLayout = .vertical,
        defaultTimeoutSeconds: Double = 30,
        defaultVerifyTLS: Bool = true,
        maxHistoryEntries: Int = 1000,
        historyRecording: HistoryRecordLevel = .metadata,
        historyBodyCapBytes: Int = 262_144,
        allowPreviewJavaScript: Bool = false,
        wrapResponseLines: Bool = true,
        showResponseLineNumbers: Bool = false,
        localAPIEnabled: Bool = false,
        localAPIPort: Int = LocalAPI.defaultPort,
        localAPIToken: String = ""
    ) {
        self.dataFolderBookmark = dataFolderBookmark
        self.dataFolderPath = dataFolderPath
        self.syncSecretsViaICloudKeychain = syncSecretsViaICloudKeychain
        self.appearance = appearance
        self.editorFontSize = editorFontSize
        self.responseLayout = responseLayout
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
        self.defaultVerifyTLS = defaultVerifyTLS
        self.maxHistoryEntries = maxHistoryEntries
        self.historyRecording = historyRecording
        self.historyBodyCapBytes = historyBodyCapBytes
        self.allowPreviewJavaScript = allowPreviewJavaScript
        self.wrapResponseLines = wrapResponseLines
        self.showResponseLineNumbers = showResponseLineNumbers
        self.localAPIEnabled = localAPIEnabled
        self.localAPIPort = localAPIPort
        self.localAPIToken = localAPIToken
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, dataFolderBookmark, dataFolderPath, syncSecretsViaICloudKeychain
        case appearance
        case editorFontSize, responseLayout, defaultTimeoutSeconds, defaultVerifyTLS
        case maxHistoryEntries, allowPreviewJavaScript, wrapResponseLines, showResponseLineNumbers
        case historyRecording, historyBodyCapBytes
        case localAPIEnabled, localAPIPort, localAPIToken
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        dataFolderBookmark = try c.decodeIfPresent(Data.self, forKey: .dataFolderBookmark)
        dataFolderPath = try c.decodeIfPresent(String.self, forKey: .dataFolderPath)
        syncSecretsViaICloudKeychain =
            try c.decodeIfPresent(Bool.self, forKey: .syncSecretsViaICloudKeychain) ?? d.syncSecretsViaICloudKeychain
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
        editorFontSize = try c.decodeIfPresent(Double.self, forKey: .editorFontSize) ?? d.editorFontSize
        responseLayout = try c.decodeIfPresent(ResponseLayout.self, forKey: .responseLayout) ?? d.responseLayout
        defaultTimeoutSeconds =
            try c.decodeIfPresent(Double.self, forKey: .defaultTimeoutSeconds) ?? d.defaultTimeoutSeconds
        defaultVerifyTLS = try c.decodeIfPresent(Bool.self, forKey: .defaultVerifyTLS) ?? d.defaultVerifyTLS
        maxHistoryEntries = try c.decodeIfPresent(Int.self, forKey: .maxHistoryEntries) ?? d.maxHistoryEntries
        historyRecording =
            try c.decodeIfPresent(HistoryRecordLevel.self, forKey: .historyRecording) ?? d.historyRecording
        historyBodyCapBytes =
            try c.decodeIfPresent(Int.self, forKey: .historyBodyCapBytes) ?? d.historyBodyCapBytes
        allowPreviewJavaScript =
            try c.decodeIfPresent(Bool.self, forKey: .allowPreviewJavaScript) ?? d.allowPreviewJavaScript
        wrapResponseLines = try c.decodeIfPresent(Bool.self, forKey: .wrapResponseLines) ?? d.wrapResponseLines
        showResponseLineNumbers =
            try c.decodeIfPresent(Bool.self, forKey: .showResponseLineNumbers) ?? d.showResponseLineNumbers
        localAPIEnabled = try c.decodeIfPresent(Bool.self, forKey: .localAPIEnabled) ?? d.localAPIEnabled
        localAPIPort = try c.decodeIfPresent(Int.self, forKey: .localAPIPort) ?? d.localAPIPort
        localAPIToken = try c.decodeIfPresent(String.self, forKey: .localAPIToken) ?? d.localAPIToken
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Postfrau.schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(dataFolderBookmark, forKey: .dataFolderBookmark)
        try c.encodeIfPresent(dataFolderPath, forKey: .dataFolderPath)
        try c.encode(syncSecretsViaICloudKeychain, forKey: .syncSecretsViaICloudKeychain)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(editorFontSize, forKey: .editorFontSize)
        try c.encode(responseLayout, forKey: .responseLayout)
        try c.encode(defaultTimeoutSeconds, forKey: .defaultTimeoutSeconds)
        try c.encode(defaultVerifyTLS, forKey: .defaultVerifyTLS)
        try c.encode(maxHistoryEntries, forKey: .maxHistoryEntries)
        try c.encode(historyRecording, forKey: .historyRecording)
        try c.encode(historyBodyCapBytes, forKey: .historyBodyCapBytes)
        try c.encode(allowPreviewJavaScript, forKey: .allowPreviewJavaScript)
        try c.encode(wrapResponseLines, forKey: .wrapResponseLines)
        try c.encode(showResponseLineNumbers, forKey: .showResponseLineNumbers)
        try c.encode(localAPIEnabled, forKey: .localAPIEnabled)
        try c.encode(localAPIPort, forKey: .localAPIPort)
        try c.encode(localAPIToken, forKey: .localAPIToken)
    }
}
