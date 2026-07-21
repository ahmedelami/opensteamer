import Foundation

/// Stable timestamp formatting for filenames and diagnostic artifacts.
public enum Timestamp {
    /// Returns the current local time using a locale-independent, filename-safe representation.
    public static func fileSafeNow() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
