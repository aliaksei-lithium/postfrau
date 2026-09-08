import Foundation

/// Namespace for package-wide constants and shared coders.
public enum Postfrau {
    /// Schema version of every persisted root document written by this build.
    public static let schemaVersion = 1

    /// Marketing version, read from the host bundle so Core does not hard-code it.
    /// The version this build reports, in the app and in the `User-Agent`.
    ///
    /// The bundle is asked first so a released app reports whatever `Info.plist` says. The
    /// fallback is not "0.0": the `postfrau` binary has no bundle at all, and a command line tool
    /// announcing itself as version 0.0 to every server it talks to is worse than one that names
    /// the version it was built from.
    public static let fallbackVersion = "1.0"

    public static let appVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? fallbackVersion

    /// The `User-Agent` sent when the user has not set one.
    public static var userAgent: String { "Postfrau/\(appVersion)" }

    /// Encoder for everything Postfrau writes to disk: stable key order, ISO-8601 dates with
    /// fractional seconds so a document round-trips to a byte-identical model.
    public static func makeEncoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(fractionalISO8601))
        }
        return encoder
    }

    /// Decoder matching `makeEncoder`. Accepts timestamps with or without fractional seconds,
    /// so documents written by other tools (or by a future build) still load.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: fractionalISO8601) { return date }
            if let date = try? Date(text, strategy: plainISO8601) { return date }
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Not an ISO-8601 timestamp: \"\(text)\""))
        }
        return decoder
    }

    private static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainISO8601 = Date.ISO8601FormatStyle()
}
