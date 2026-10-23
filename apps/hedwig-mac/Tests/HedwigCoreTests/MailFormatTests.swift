import Foundation
import Testing
@testable import HedwigCore

struct MailFormatTests {
    private let format: MailFormat = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return MailFormat(calendar: calendar, locale: Locale(identifier: "nl_NL"))
    }()

    private func date(_ day: Int, _ month: Int, _ hour: Int, _ minute: Int) -> Date {
        format.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { date(23, 10, 12, 0) }

    @Test func theListShowsTimeTodayThenGisterenThenTheDateLikeMail() {
        #expect(format.listDate(date(23, 10, 6, 54), now: now) == "06:54")
        #expect(format.listDate(date(22, 10, 17, 6), now: now) == "Gisteren")
        #expect(format.listDate(date(20, 10, 9, 0), now: now) == "20-10-2026")
    }

    @Test func theHeaderAddsTheTimeExceptToday() {
        #expect(format.headerDate(date(23, 10, 6, 54), now: now) == "06:54")
        #expect(format.headerDate(date(22, 10, 17, 6), now: now) == "Gisteren om 17:06")
        #expect(format.headerDate(date(3, 9, 22, 1), now: now) == "3 september 2026 om 22:01")
    }

    @Test func countsGroupThousandsLikeMail() {
        #expect(format.count(total: 27825, unread: 15) == "27.825 berichten, 15 ongelezen")
        #expect(format.count(total: 1, unread: 0) == "1 bericht")
        #expect(format.count(total: 1200, unread: 0) == "1.200 berichten")
    }
}
