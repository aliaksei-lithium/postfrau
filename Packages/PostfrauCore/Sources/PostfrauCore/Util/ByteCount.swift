import Foundation

/// Human-readable byte counts, without dragging `ByteCountFormatter`'s locale behaviour into
/// places that need a stable, compact string (status line, history rows, tests).
public enum ByteCount {
    /// `842 B`, `2.3 KB`, `19.7 MB` — one decimal place above a kilobyte, none below.
    public static func format(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0
            ? "\(bytes) B"
            : String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }

    /// `142 ms`, `1.42 s`, `1 m 07 s` — the response header's duration.
    public static func formatDuration(milliseconds: Double) -> String {
        if milliseconds < 1000 { return "\(Int(milliseconds.rounded())) ms" }
        let seconds = milliseconds / 1000
        if seconds < 60 { return String(format: "%.2f s", seconds) }
        return String(format: "%d m %02.0f s", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}
