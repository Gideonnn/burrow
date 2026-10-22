import Foundation

/// The one sentence an outing shows in the list (design v2): the most urgent
/// thing, or that all is well.
public struct OutingStatus: Hashable, Sendable {
    public enum Tone: Sendable { case today, todo, later, done, past }
    public var text: String
    public var tone: Tone
}

extension Outing {
    /// Within four weeks an open item is something to do now.
    public static let urgentDays = 28
    /// Within two weeks an outing without tickets needs them.
    public static let ticketDays = 14

    public func isPast(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endsAt ?? startsAt)) else { return false }
        return now >= dayAfter
    }

    /// On the day itself, or any day of a festival.
    public func isToday(now: Date = .now, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: startsAt) <= now && !isPast(now: now, calendar: calendar)
    }

    /// "Vanavond" from five in the afternoon, otherwise "Vandaag".
    public func dayWord(calendar: Calendar = .current) -> String {
        !allDay && calendar.component(.hour, from: startsAt) >= 17 ? "Vanavond" : "Vandaag"
    }

    /// Open items, most urgent first; one without a date is due on the day.
    public func openItems() -> [(task: OutingTask, due: Date)] {
        checklist.filter { !$0.done }.map { ($0, $0.dueAt ?? startsAt) }.sorted { $0.due < $1.due }
    }

    private func within(_ days: Int, _ date: Date, of now: Date, _ calendar: Calendar) -> Bool {
        guard let limit = calendar.date(byAdding: .day, value: days, to: now) else { return false }
        return date < limit
    }

    private func urgentItem(now: Date, calendar: Calendar) -> OutingTask? {
        openItems().first { within(Self.urgentDays, $0.due, of: now, calendar) }?.task
    }

    private func needsTickets(now: Date, calendar: Calendar) -> Bool {
        tickets.isEmpty && within(Self.ticketDays, startsAt, of: now, calendar)
    }

    /// What the sidebar badge counts: an upcoming outing with an open item
    /// due within four weeks, or without tickets two weeks before.
    public func needsAttention(now: Date = .now, calendar: Calendar = .current) -> Bool {
        !isPast(now: now, calendar: calendar)
            && (urgentItem(now: now, calendar: calendar) != nil || needsTickets(now: now, calendar: calendar))
    }

    public func status(now: Date = .now, calendar: Calendar = .current) -> OutingStatus {
        if isPast(now: now, calendar: calendar) { return OutingStatus(text: "Geweest", tone: .past) }
        if isToday(now: now, calendar: calendar) {
            return OutingStatus(text: [dayWord(calendar: calendar), venue].compactMap { $0 }.joined(separator: " · "), tone: .today)
        }
        if let task = urgentItem(now: now, calendar: calendar) {
            return OutingStatus(text: "Nog doen: \(task.title.lowercasedFirst)", tone: .todo)
        }
        if needsTickets(now: now, calendar: calendar) { return OutingStatus(text: "Nog doen: kaarten toevoegen", tone: .todo) }
        if let later = openItems().first?.task {
            return OutingStatus(text: "Later: \(later.title.lowercasedFirst)", tone: .later)
        }
        if tickets.isEmpty { return OutingStatus(text: "Kaarten toevoegen", tone: .later) }
        return OutingStatus(text: "Alles geregeld", tone: .done)
    }
}

extension String {
    /// "Kaarten op naam zetten" reads as "nog doen: kaarten op naam zetten".
    public var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

// MARK: Dutch dates

/// Dates as the Evenementen page writes them: "za 7 nov, 20:15", the year
/// only when it is not this year.
public enum OutingFormat {
    public static let locale = Locale(identifier: "nl_NL")

    private static let countries: Set<String> = [
        "nederland", "netherlands", "the netherlands", "belgië", "belgie", "belgium", "belgique",
        "deutschland", "duitsland", "germany", "frankrijk", "france",
    ]

    /// Waar on two lines: the venue, then the address without the venue and
    /// without the country the map already shows.
    public static func whereLines(venue: String?, address: String?) -> [String] {
        let clean = { (text: String?) in text?.trimmingCharacters(in: .whitespaces).nilIfEmpty }
        let venue = clean(venue)
        var parts = (clean(address) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parts.count > 1, let last = parts.last, countries.contains(last.lowercased()) { parts.removeLast() }
        if let venue, parts.first?.lowercased() == venue.lowercased() { parts.removeFirst() }
        let rest = parts.isEmpty ? nil : parts.joined(separator: ", ")
        return [venue, rest].compactMap { $0 }
    }

    public static func whereLines(_ outing: Outing) -> [String] {
        whereLines(venue: outing.venue, address: outing.address)
    }

    private static func string(_ date: Date, _ format: String, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f.string(from: date)
    }

    public static func month(_ date: Date, calendar: Calendar = .current) -> String { string(date, "LLL", calendar) }

    public static func day(_ date: Date, calendar: Calendar = .current) -> String { string(date, "d", calendar) }

    public static func time(_ date: Date, calendar: Calendar = .current) -> String { string(date, "HH:mm", calendar) }

    public static func date(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return string(date, sameYear ? "EEE d MMM" : "EEE d MMM yyyy", calendar)
    }

    /// "za 7 nov, 20:15", "Vanavond, 20:00" or "vr 18 tot zo 20 jun 2027".
    public static func when(_ outing: Outing, now: Date = .now, calendar: Calendar = .current) -> String {
        let start = outing.startsAt
        if let end = outing.endsAt, !calendar.isDate(end, inSameDayAs: start) {
            return "\(date(start, now: now, calendar: calendar)) tot \(date(end, now: now, calendar: calendar))"
        }
        let day = calendar.isDate(start, inSameDayAs: now) ? outing.dayWord(calendar: calendar) : date(start, now: now, calendar: calendar)
        return outing.allDay ? day : "\(day), \(time(start, calendar: calendar))"
    }

    /// Whole days from today to the date's day.
    public static func daysLeft(until date: Date, now: Date = .now, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// "vóór di 27 okt · nog 5 dagen"
    public static func due(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = daysLeft(until: date, now: now, calendar: calendar)
        let left = switch days {
        case ..<0: "te laat"
        case 0: "vandaag"
        case 1: "morgen"
        default: "nog \(days) dagen"
        }
        return "vóór \(self.date(date, now: now, calendar: calendar)) · \(left)"
    }
}

// MARK: Reminders until Patronus

/// A local notification the Mac schedules until Patronus sends the tickets
/// and deadlines to Telegram.
public struct OutingReminder: Hashable, Sendable {
    public var id: String
    public var outingId: String
    public var fireAt: Date
    public var title: String
    public var body: String
}

extension Outing {
    /// Deadline reminders four weeks and one week before.
    public static let reminderDays = [28, 7]

    public func reminders(now: Date = .now, calendar: Calendar = .current) -> [OutingReminder] {
        var all: [OutingReminder] = []
        let at = { (day: Date, hour: Int) in calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) }
        // At nine on the day, or at noon the day before for a morning start.
        let morning = !allDay && calendar.component(.hour, from: startsAt) < 10
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: startsAt)
        if let fire = morning ? dayBefore.flatMap({ at($0, 12) }) : at(startsAt, 9) {
            let start = allDay ? nil : (doorsAt.map { "Deuren \(OutingFormat.time($0, calendar: calendar))" } ?? OutingFormat.time(startsAt, calendar: calendar))
            all.append(OutingReminder(
                id: "outing.\(id).day", outingId: id, fireAt: fire,
                title: "\(morning ? "Morgen" : dayWord(calendar: calendar)): \(title)",
                body: [start, venue].compactMap { $0 }.joined(separator: " · ")))
        }
        for task in checklist where !task.done {
            guard let due = task.dueAt else { continue }
            for days in Self.reminderDays {
                guard let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: due)), let fire = at(day, 9) else { continue }
                all.append(OutingReminder(
                    id: "outing.\(id).task.\(task.id).\(days)", outingId: id, fireAt: fire,
                    title: "\(task.title) voor \(title), nog \(days) dagen",
                    body: "Vóór \(OutingFormat.date(due, now: fire, calendar: calendar))"))
            }
        }
        return all.filter { $0.fireAt > now }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
