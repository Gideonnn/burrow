import Foundation
import Testing
@testable import HedwigCore

@Suite struct OutingLineupTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()

    private static let json = """
    {"status":"ready","error":null,"complete":false,"note":"Meer namen volgen.","sources":["https://www.festival.example.com/line-up"],
     "updatedAt":"2026-10-22T08:00:00.000Z","artists":[
      {"name":"SOMBR","day":"2027-07-04","stage":"Main Stage","startsAt":null,"headliner":false},
      {"name":"Muse","day":"2027-07-02","stage":null,"startsAt":null,"headliner":true},
      {"name":"Angèle","day":"2027-07-04","stage":"Main Stage","startsAt":"18:30","headliner":false},
      {"name":"Nieuwe Naam","day":null,"stage":null,"startsAt":null,"headliner":false},
      {"name":"Tame Impala","day":"2027-07-04","stage":"Main Stage","startsAt":"23:00","headliner":true},
      {"name":"Sam Fender","day":"2027-07-03","stage":"Main Stage","startsAt":null,"headliner":true}]}
    """

    private static func lineup() throws -> OutingLineup {
        try APIClient.decoder.decode(OutingLineup.self, from: Data(json.utf8))
    }

    @Test func groupsPerDayWithHeadlinersFirst() throws {
        let days = try Self.lineup().days(calendar: Self.calendar)
        #expect(days.map(\.title) == ["Vrijdag 2 juli", "Zaterdag 3 juli", "Zondag 4 juli", "Nog geen dag"])
        #expect(days[2].artists.map(\.name) == ["Tame Impala", "Angèle", "SOMBR"])
        #expect(days[2].headliners.map(\.name) == ["Tame Impala"])
        #expect(days[2].artists.first?.detail == "Main Stage · 23:00")
        #expect(days[3].artists.map(\.name) == ["Nieuwe Naam"])
    }

    @Test func saysWhereAndWhenItWasRead() throws {
        let lineup = try Self.lineup()
        #expect(lineup.sourceHost == "festival.example.com")
        #expect(lineup.updatedText(now: lineup.updatedAt.addingTimeInterval(20)) == "Bijgewerkt zojuist")
        #expect(lineup.updatedText(now: lineup.updatedAt.addingTimeInterval(3 * 3600)) == "Bijgewerkt 3 uur geleden")
    }

    @Test func aMissingOrUnknownStatusStillDecodes() throws {
        let odd = try APIClient.decoder.decode(
            OutingLineup.self,
            from: Data(#"{"status":"queued","error":null,"artists":[],"complete":false,"note":null,"sources":[],"updatedAt":"2026-10-22T08:00:00.000Z"}"#.utf8))
        #expect(odd.status == .ready)
        #expect(odd.days().isEmpty)
    }
}
