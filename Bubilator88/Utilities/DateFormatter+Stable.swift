import Foundation

extension DateFormatter {
    /// Build a DateFormatter pinned to `en_US_POSIX` so patterns like
    /// `yyyy` always resolve to Gregorian-calendar year numbers, independent
    /// of the user's system locale. Required wherever the output goes into
    /// a file name or a string parsed later — otherwise a Japanese (era)
    /// calendar turns "2026" into "0008".
    static func stable(pattern: String) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = pattern
        return fmt
    }
}
