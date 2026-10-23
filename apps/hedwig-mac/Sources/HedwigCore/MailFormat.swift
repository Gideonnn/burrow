import Foundation

/// Dates and counts written the way Apple Mail writes them: "06:54",
/// "Gisteren", "20-10-2026" in the list; "Gisteren om 17:06" in the header.
public struct MailFormat: Sendable {
    public let calendar: Calendar
    public let locale: Locale

    public init(calendar: Calendar = .current, locale: Locale = .current) {
        self.calendar = calendar
        self.locale = locale
    }

    public func listDate(_ date: Date, now: Date = .now) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return formatter(date: .none, time: .short).string(from: date) }
        if isYesterday(date, now: now) { return "Gisteren" }
        return formatter(date: .short, time: .none).string(from: date)
    }

    public func headerDate(_ date: Date, now: Date = .now) -> String {
        let time = formatter(date: .none, time: .short).string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if isYesterday(date, now: now) { return "Gisteren om \(time)" }
        return formatter(date: .long, time: .short).string(from: date)
    }

    public func count(total: Int, unread: Int) -> String {
        let messages = total == 1 ? "1 bericht" : "\(number(total)) berichten"
        return unread > 0 ? "\(messages), \(number(unread)) ongelezen" : messages
    }

    private func number(_ value: Int) -> String { value.formatted(.number.locale(locale)) }

    // DateFormatter's own relative formatting compares with the real clock, not `now`.
    private func isYesterday(_ date: Date, now: Date) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }

    private func formatter(date: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = date
        formatter.timeStyle = time
        return formatter
    }
}
