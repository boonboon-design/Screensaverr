import Foundation

enum Formatting {

    // MARK: Sizes & speeds (binary units, like SABnzbd)

    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    static func bytes(_ value: Double) -> String {
        let (number, unit) = scaled(value)
        return "\(number) \(unit)"
    }

    /// ("42.3", "MB/s")
    static func speedParts(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let (number, unit) = scaled(bytesPerSecond)
        return (number, unit + "/s")
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        let parts = speedParts(bytesPerSecond)
        return "\(parts.value) \(parts.unit)"
    }

    private static func scaled(_ value: Double) -> (String, String) {
        guard value.isFinite, value > 0 else { return ("0", "B") }
        var amount = value
        var index = 0
        while amount >= 1024 && index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        let text: String
        if index == 0 || amount >= 100 {
            text = String(format: "%.0f", amount)
        } else {
            text = String(format: "%.1f", amount)
        }
        return (text, units[index])
    }

    // MARK: Durations

    /// Parses SABnzbd's "H:MM:SS" or "D:HH:MM:SS".
    static func parseSABTime(_ text: String?) -> TimeInterval? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let parts = text.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        var seconds = 0
        for part in parts { seconds = seconds * 60 + (part ?? 0) }
        if parts.count == 4, let days = parts[0], let hours = parts[1], let minutes = parts[2], let secs = parts[3] {
            seconds = ((days * 24 + hours) * 60 + minutes) * 60 + secs
        }
        return TimeInterval(seconds)
    }

    /// "45s", "12m", "1h 05m", "2d 3h"
    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "0s" }
        let total = Int(interval.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    // MARK: Dates

    /// "Today", "Tomorrow", "Wednesday", "Oct 21", "Oct 21, 2027"
    static func dayLabel(for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return formatted(date, template: "EEEE", calendar: calendar, locale: locale)
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return formatted(date, template: sameYear ? "MMMd" : "MMMdy", calendar: calendar, locale: locale)
        }
    }

    /// "Today · 9:00 PM", "Tomorrow · 21:00"
    static func airLabel(for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let day = dayLabel(for: date, now: now, calendar: calendar, locale: locale)
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        guard (-1...6).contains(offset) else { return day }
        return "\(day) · \(time(date, calendar: calendar, locale: locale))"
    }

    static func time(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func formatted(_ date: Date, template: String, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// "just now", "5m ago", "3h ago", "2d ago"
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        if seconds < 86_400 * 60 { return "\(Int(seconds / 86_400))d ago" }
        return "\(Int(seconds / (86_400 * 30)))mo ago"
    }
}
