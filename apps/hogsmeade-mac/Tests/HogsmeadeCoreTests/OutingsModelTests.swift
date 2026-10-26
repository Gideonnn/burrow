import Foundation
import Testing
@testable import HogsmeadeCore

enum Fixture {
    static let me = """
    {"person":{"id":"p1","name":"Ada"},"key":{"id":"k1","name":"Hogsmeade op Testmac"},
     "rights":["read","organize"],"mailboxes":[],"admin":true}
    """
    static let people = #"[{"id":"p1","name":"Ada"},{"id":"p2","name":"Bram"}]"#

    /// An outing on `date` (ISO), with or without tickets and open items.
    static func outing(
        _ id: String, _ title: String, date: String, kind: String = "feest", venue: String = "De Kolenloods",
        tickets: Bool = true, open: Bool = false, attendees: [String] = ["p1", "p2"]
    ) -> String {
        let who = attendees.map { #"{"id":"\#($0)","name":"\#($0 == "p1" ? "Ada" : "Bram")"}"# }.joined(separator: ",")
        let ticket = tickets
            ? #"[{"id":"t-\#(id)","name":"kaart.pdf","contentType":"application/pdf","size":10,"holder":null,"personalised":false,"messageId":null,"addedBy":{"id":"p1","name":"Ada"},"addedAt":"2026-10-01T10:00:00.000Z"}]"#
            : "[]"
        let task = open
            ? #"[{"id":"task-\#(id)","kind":"custom","title":"Oppas regelen","dueAt":null,"assignee":null,"doneAt":null,"doneBy":null}]"#
            : "[]"
        return """
        {"id":"\(id)","title":"\(title)","kind":"\(kind)","startsAt":"\(date)","endsAt":null,"doorsAt":null,"allDay":false,
         "venue":"\(venue)","address":"Kolenkade 12, Amsterdam, Nederland","organiser":null,"vendor":"Weeztix","orderNumber":null,"url":null,"notes":"","aliases":[],
         "inCalendar":false,"image":null,"attendees":[\(who)],"tickets":\(ticket),"tasks":\(task),"mails":[],"lineup":null,"ticketLinks":[],
         "createdBy":{"id":"p1","name":"Ada"},"createdAt":"2026-10-01T10:00:00.000Z","updatedBy":{"id":"p1","name":"Ada"},"updatedAt":"2026-10-01T10:00:00.000Z"}
        """
    }
}

/// A tiny server whose outings follow the test's changes.
final class Household: @unchecked Sendable {
    private let lock = NSLock()
    var done: Set<String> = []

    /// Tonight, a party in a month with something to do, a play without tickets, and one that was.
    func list() -> String {
        lock.withLock {
            "[" + [
                Fixture.outing("o1", "Neon Nineties", date: "2026-10-28T20:00:00.000Z"),
                Fixture.outing("o2", "Foute Vrijdag XL", date: "2026-11-27T21:00:00.000Z", open: !done.contains("task-o2")),
                Fixture.outing("o3", "Stille Wateren", date: "2026-12-12T19:30:00.000Z", kind: "theater", venue: "Stadsschouwburg", tickets: false, attendees: ["p1"]),
                Fixture.outing("o4", "Welcome To The 90's", date: "2026-10-03T21:00:00.000Z"),
            ].joined(separator: ",") + "]"
        }
    }

    func setDone(_ id: String, _ value: Bool) -> String {
        lock.withLock {
            if value { done.insert(id) } else { done.remove(id) }
            return Fixture.outing("o2", "Foute Vrijdag XL", date: "2026-11-27T21:00:00.000Z", open: !done.contains("task-o2"))
        }
    }
}

@MainActor
@Suite(.serialized) struct OutingsModelTests {
    static let today = ISO8601DateFormatter().date(from: "2026-10-28T09:00:00Z")!

    func model(_ server: MockServer) -> OutingsModel {
        let client = server.client()
        let model = OutingsModel(
            store: ConnectionStore(service: "app.burrow.hogsmeade.tests"), makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
        model.toastSeconds = nil
        model.now = { Self.today }
        return model
    }

    func server(_ household: Household = Household()) -> MockServer {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/people", json: Fixture.people)
        server.on("GET", "/api/outings") { _ in (200, household.list()) }
        server.on("PATCH", "/api/outings/o2/tasks/task-o2") { request in
            let body = request.httpBodyStream.map(readBody) ?? request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return (200, household.setDone("task-o2", body.contains(#""done":true"#)))
        }
        server.on("POST", "/api/outings") { _ in
            (201, Fixture.outing("o9", "Schaatsen", date: "2026-12-20T19:00:00.000Z", kind: "uitje", venue: "Jaap Eden", tickets: false))
        }
        return server
    }

    func started(_ server: MockServer) async -> OutingsModel {
        let model = model(server)
        await model.start()
        return model
    }

    @Test func sortsTonightFirstAndGeweestApart() async {
        let model = await started(server())
        #expect(model.upcoming.map(\.title) == ["Neon Nineties", "Foute Vrijdag XL", "Stille Wateren"])
        #expect(model.past.map(\.title) == ["Welcome To The 90's"])
        #expect(model.today?.title == "Neon Nineties")
        #expect(model.next?.title == "Neon Nineties")
        #expect(model.nights(until: model.upcoming[1]) == 30)
        #expect(model.nightsLabel(model.upcoming[0]) == "vanavond!")
        #expect(model.nightsLabel(model.upcoming[1]) == "nog 30 nachtjes")
        #expect(model.summaryLine == "3 uitjes")
        #expect(model.others(on: model.upcoming[0]) == ["Bram"])
        #expect(OutingsModel.sentence(["Eva", "Sanne", "Joris"]) == "Eva, Sanne en Joris")
    }

    @Test func theSidebarNarrowsByPersonAndKindAndTheSearchByWords() async {
        let model = await started(server())
        #expect(model.kinds.map { "\($0.label) \($0.count)" } == ["Feest 2", "Theater 1"])
        #expect(model.count(for: model.people[1]) == 2)
        model.filter = .kind("theater")
        #expect(model.shown.map(\.title) == ["Stille Wateren"])
        model.filter = .person("p2")
        #expect(model.shown.map(\.title) == ["Neon Nineties", "Foute Vrijdag XL"])
        model.filter = nil
        model.query = "kolenloods"
        #expect(model.shown.map(\.title) == ["Neon Nineties", "Foute Vrijdag XL"])
        model.page = .past
        model.query = ""
        #expect(model.shown.map(\.title) == ["Welcome To The 90's"])
    }

    @Test func aPosterGetsOneStamp() async {
        let model = await started(server())
        #expect(model.upcoming[0].wallStamp() == WallStamp(text: "Geregeld!", tone: .ok))
        #expect(model.upcoming[1].wallStamp() == WallStamp(text: "Nog doen", tone: .todo))
        #expect(model.upcoming[2].wallStamp() == WallStamp(text: "Kaartjes?", tone: .tickets))
        #expect(model.upcoming[0].kindAndVenue == "Feest · De Kolenloods")
        #expect(model.upcoming[0].city == "Amsterdam")
    }

    @Test func tickingTheLastItemCelebrates() async {
        let server = server()
        let model = await started(server)
        let party = model.upcoming[1]
        await model.setTask(party.tasks[0], done: true, in: party)
        #expect(server.requests("PATCH", "/api/outings/o2/tasks/task-o2").last == #"{"done":true}"#)
        #expect(model.lastChange?.kind == .allDone)
        #expect(model.toast?.message == "Alles geregeld voor Foute Vrijdag XL!")
        #expect(model.upcoming[1].wallStamp().tone == .ok)
    }

    @Test func aNewOutingHangsOnTheWallAndOpens() async {
        let server = server()
        let model = await started(server)
        await model.create(title: " Schaatsen ", startsAt: Self.today, venue: "Jaap Eden")
        #expect(server.requests("POST", "/api/outings").last?.contains(#""title":"Schaatsen""#) == true)
        #expect(model.open?.title == "Schaatsen")
        #expect(model.lastChange?.kind == .created)
        model.escape()
        #expect(model.open == nil)
    }
}

private func readBody(_ stream: InputStream) -> String {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    return String(decoding: data, as: UTF8.self)
}
