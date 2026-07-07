import Foundation

enum CompanionTimezone {
    static func resolve(identifier: String?) -> TimeZone {
        if let identifier,
           !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let timeZone = TimeZone(identifier: identifier)
        {
            return timeZone
        }
        return TimeZone.current
    }

    static func localContext(for timeZone: TimeZone, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let formatted = formatter.string(from: now)
        return "\(formatted) (\(timeZone.identifier), \(utcOffsetLabel(for: timeZone, at: now)))"
    }

    static func iso8601Offset(for timeZone: TimeZone, at date: Date = Date()) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let hours = seconds / 3600
        let minutes = abs(seconds / 60) % 60
        let sign = seconds >= 0 ? "+" : "-"
        return String(format: "%@%02d:%02d", sign, abs(hours), minutes)
    }

    static func formatDate(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        return formatter.string(from: date)
    }

    static func hasNumericOffset(_ string: String) -> Bool {
        string.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil
    }

    static func hasExplicitTimeZone(_ string: String) -> Bool {
        if string.hasSuffix("Z") { return true }
        return hasNumericOffset(string)
    }

    /// Parses a datetime for task/calendar tools.
    /// - Numeric offsets (`+08:00`) are parsed as absolute instants.
    /// - Bare datetimes and `Z` suffixes are treated as **wall-clock local time**
    ///   in `timeZone` (fixes the common model mistake of using `T20:00:00Z` for "8pm").
    static func parseCompanionDate(_ string: String, in timeZone: TimeZone) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasNumericOffset(trimmed) {
            return parseISO8601Instant(trimmed)
        }
        return parseWallClockDate(trimmed, in: timeZone)
    }

    static func parseWallClockDate(_ string: String, in timeZone: TimeZone) -> Date? {
        var value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("Z") {
            value = String(value.dropLast())
        }
        if let dot = value.firstIndex(of: ".") {
            value = String(value[..<dot])
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func parseISO8601Instant(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    private static func utcOffsetLabel(for timeZone: TimeZone, at date: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let hours = seconds / 3600
        let minutes = abs(seconds / 60) % 60
        if minutes == 0 {
            return hours >= 0 ? "UTC+\(hours)" : "UTC\(hours)"
        }
        let sign = hours >= 0 ? "+" : "-"
        return String(format: "UTC%@%d:%02d", sign, abs(hours), minutes)
    }
}
