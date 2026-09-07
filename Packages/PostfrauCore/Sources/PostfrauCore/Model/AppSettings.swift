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

/// Machine-local preferences. Written to `settings.json` in the local state folder; never synced.
public struct AppSettings: Sendable, Hashable, Codable {
    /// Security-scoped bookmark to the user's chosen data folder.
    public var dataFolderBookmark: Data?
    /// Last known path of that folder, shown in Settings even when the bookmark is stale.
    public var dataFolderPath: String?
    public var syncSecretsViaICloudKeychain: Bool
    public var editorFontSize: Double
    public var responseLayout: ResponseLayout
    public var defaultTimeoutSeconds: Double
    public var defaultVerifyTLS: Bool
    public var maxHistoryEntries: Int
    /// Whether the HTML preview may run JavaScript and load subresources. Off by default so a
    /// previewed response cannot phone home.
    public var allowPreviewJavaScript: Bool
    public var wrapResponseLines: Bool
    public var showResponseLineNumbers: Bool

    public init(
        dataFolderBookmark: Data? = nil,
        dataFolderPath: String? = nil,
        syncSecretsViaICloudKeychain: Bool = false,
        editorFontSize: Double = 12,
        responseLayout: ResponseLayout = .vertical,
        defaultTimeoutSeconds: Double = 30,
        defaultVerifyTLS: Bool = true,
        maxHistoryEntries: Int = 1000,
        allowPreviewJavaScript: Bool = false,
        wrapResponseLines: Bool = true,
        showResponseLineNumbers: Bool = false
    ) {
        self.dataFolderBookmark = dataFolderBookmark
        self.dataFolderPath = dataFolderPath
        self.syncSecretsViaICloudKeychain = syncSecretsViaICloudKeychain
        self.editorFontSize = editorFontSize
        self.responseLayout = responseLayout
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
        self.defaultVerifyTLS = defaultVerifyTLS
        self.maxHistoryEntries = maxHistoryEntries
        self.allowPreviewJavaScript = allowPreviewJavaScript
        self.wrapResponseLines = wrapResponseLines
        self.showResponseLineNumbers = showResponseLineNumbers
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, dataFolderBookmark, dataFolderPath, syncSecretsViaICloudKeychain
        case editorFontSize, responseLayout, defaultTimeoutSeconds, defaultVerifyTLS
        case maxHistoryEntries, allowPreviewJavaScript, wrapResponseLines, showResponseLineNumbers
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        dataFolderBookmark = try c.decodeIfPresent(Data.self, forKey: .dataFolderBookmark)
        dataFolderPath = try c.decodeIfPresent(String.self, forKey: .dataFolderPath)
        syncSecretsViaICloudKeychain =
            try c.decodeIfPresent(Bool.self, forKey: .syncSecretsViaICloudKeychain) ?? d.syncSecretsViaICloudKeychain
        editorFontSize = try c.decodeIfPresent(Double.self, forKey: .editorFontSize) ?? d.editorFontSize
        responseLayout = try c.decodeIfPresent(ResponseLayout.self, forKey: .responseLayout) ?? d.responseLayout
        defaultTimeoutSeconds =
            try c.decodeIfPresent(Double.self, forKey: .defaultTimeoutSeconds) ?? d.defaultTimeoutSeconds
        defaultVerifyTLS = try c.decodeIfPresent(Bool.self, forKey: .defaultVerifyTLS) ?? d.defaultVerifyTLS
        maxHistoryEntries = try c.decodeIfPresent(Int.self, forKey: .maxHistoryEntries) ?? d.maxHistoryEntries
        allowPreviewJavaScript =
            try c.decodeIfPresent(Bool.self, forKey: .allowPreviewJavaScript) ?? d.allowPreviewJavaScript
        wrapResponseLines = try c.decodeIfPresent(Bool.self, forKey: .wrapResponseLines) ?? d.wrapResponseLines
        showResponseLineNumbers =
            try c.decodeIfPresent(Bool.self, forKey: .showResponseLineNumbers) ?? d.showResponseLineNumbers
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Postfrau.schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(dataFolderBookmark, forKey: .dataFolderBookmark)
        try c.encodeIfPresent(dataFolderPath, forKey: .dataFolderPath)
        try c.encode(syncSecretsViaICloudKeychain, forKey: .syncSecretsViaICloudKeychain)
        try c.encode(editorFontSize, forKey: .editorFontSize)
        try c.encode(responseLayout, forKey: .responseLayout)
        try c.encode(defaultTimeoutSeconds, forKey: .defaultTimeoutSeconds)
        try c.encode(defaultVerifyTLS, forKey: .defaultVerifyTLS)
        try c.encode(maxHistoryEntries, forKey: .maxHistoryEntries)
        try c.encode(allowPreviewJavaScript, forKey: .allowPreviewJavaScript)
        try c.encode(wrapResponseLines, forKey: .wrapResponseLines)
        try c.encode(showResponseLineNumbers, forKey: .showResponseLineNumbers)
    }
}
