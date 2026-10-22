import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite(.serialized) struct OutingTests {
    private static let suggestion = """
    {"outingId":null,"title":"Neon Nineties","kind":"concert","startsAt":"2027-05-13T19:00:00.000Z","endsAt":null,
     "doorsAt":null,"venue":"Voorbeeldhal","address":null,"organiser":null,"vendor":"Kaartloket","orderNumber":"KL-48291",
     "url":null,"personaliseBy":"2027-04-29T00:00:00.000Z","aliases":["Neon Nineties","Kaartloket"],
     "tickets":[{"id":"a1","name":"kaarten.pdf","contentType":"application/pdf","size":2000}],"confidence":"structured"}
    """
    private static let outing = """
    {"id":"o1","title":"Neon Nineties","kind":"concert","startsAt":"2027-05-13T19:00:00.000Z","endsAt":null,"doorsAt":null,
     "allDay":false,"venue":"Voorbeeldhal","address":null,"organiser":null,"vendor":"Kaartloket","orderNumber":"KL-48291",
     "url":null,"notes":"","aliases":["Neon Nineties"],"inCalendar":false,
     "attendees":[{"id":"p1","name":"Gideon"},{"id":"p2","name":"Eva"}],
     "tickets":[{"id":"t1","name":"kaarten.pdf","contentType":"application/pdf","size":2000,"holder":null,"personalised":false,
       "messageId":"m1","addedBy":{"id":"p1","name":"Gideon"},"addedAt":"2026-10-22T08:00:00.000Z"}],
     "tasks":[{"id":"k1","kind":"calendar","title":"In de agenda zetten","dueAt":null,"assignee":null,"doneAt":null,"doneBy":null},
       {"id":"k2","kind":"personalise","title":"Kaarten op naam zetten","dueAt":"2027-04-29T00:00:00.000Z","assignee":null,"doneAt":null,"doneBy":null}],
     "mails":[{"id":"m1","visible":true,"owner":{"id":"p1","name":"Gideon"},"subject":"Je bestelling","from":{"email":"tickets@kaartloket.example.com"},"receivedAt":"2026-10-22T08:00:00.000Z"}],
     "createdBy":{"id":"p1","name":"Gideon"},"createdAt":"2026-10-22T08:00:00.000Z",
     "updatedBy":{"id":"p1","name":"Gideon"},"updatedAt":"2026-10-22T08:00:00.000Z"}
    """

    private func model(_ server: MockServer) -> AppModel {
        let client = server.client()
        return AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
    }

    @Test func anOrderMailBecomesASharedOutingInOneClick() async throws {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/mailboxes/mb1/messages", json: "[\(Fixture.message("m1", subject: "Je bestelling", unread: false))]")
        server.on("GET", "/api/messages/m1", json: Fixture.message("m1", subject: "Je bestelling", unread: false))
        server.on("GET", "/api/messages/m1/outing", json: Self.suggestion)
        server.on("POST", "/api/outings", json: Self.outing)
        let model = model(server)
        await model.start()
        model.selection = .inbox(mailboxId: "mb1")
        await model.loadSelection()
        await model.openSelected()
        #expect(model.showsOutingCard)
        #expect(model.outing == nil)

        await model.saveOuting()
        let body = try #require(server.requests("POST", "/api/outings").last)
        #expect(body.contains(#""startsAt":"2027-05-13T19:00:00.000Z""#))
        #expect(body.contains(#""personaliseBy":"2027-04-29T00:00:00.000Z""#))
        #expect(body.contains(#""messageId":"m1""#))
        #expect(body.contains(#""attachmentIds":["a1"]"#))
        #expect(!body.contains("endsAt"))
        #expect(model.outing?.openPersonalise?.id == "k2")
        #expect(model.outing?.tickets.first?.holder == nil)
    }

    @Test func ordinaryMailHasNoCard() async throws {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/mailboxes/mb1/messages", json: "[\(Fixture.message("m1", subject: "Etentje", unread: false))]")
        server.on("GET", "/api/messages/m1", json: Fixture.message("m1", subject: "Etentje", unread: false))
        server.on("GET", "/api/messages/m1/outing", json: Self.suggestion
            .replacingOccurrences(of: #""confidence":"structured""#, with: #""confidence":"none""#))
        let model = model(server)
        await model.start()
        model.selection = .inbox(mailboxId: "mb1")
        await model.loadSelection()
        await model.openSelected()
        #expect(!model.showsOutingCard)
    }

    // MARK: The Evenementen page

    private static let amsterdam: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()
    private static let now = APIClient.isoFractional.date(from: "2026-10-22T08:00:00.000Z")!

    private static func task(_ id: String, _ title: String, due: String? = nil, done: Bool = false, kind: String = "custom") -> String {
        """
        {"id":"\(id)","kind":"\(kind)","title":"\(title)","dueAt":\(due.map { "\"\($0)\"" } ?? "null"),"assignee":null,
         "doneAt":\(done ? "\"2026-10-21T10:00:00.000Z\"" : "null"),"doneBy":\(done ? #"{"id":"p2","name":"Eva"}"# : "null")}
        """
    }

    private static func outingJSON(
        _ id: String, _ title: String, startsAt: String, venue: String? = "Voorbeeldhal", tickets: Int = 2, tasks: [String] = []
    ) -> String {
        let ticket = { (n: Int) in
            """
            {"id":"t\(n)","name":"kaart\(n).pdf","contentType":"application/pdf","size":2000,"holder":null,"personalised":false,
             "messageId":null,"addedBy":{"id":"p1","name":"Gideon"},"addedAt":"2026-10-01T08:00:00.000Z"}
            """
        }
        return """
        {"id":"\(id)","title":"\(title)","kind":"cabaret","startsAt":"\(startsAt)","endsAt":null,"doorsAt":null,"allDay":false,
         "venue":\(venue.map { "\"\($0)\"" } ?? "null"),"address":null,"organiser":null,"vendor":null,"orderNumber":null,"url":null,
         "notes":"","aliases":[],"inCalendar":false,"attendees":[{"id":"p1","name":"Gideon"},{"id":"p2","name":"Eva"}],
         "tickets":[\((0..<tickets).map(ticket).joined(separator: ","))],"tasks":[\(tasks.joined(separator: ","))],"mails":[],
         "createdBy":{"id":"p1","name":"Gideon"},"createdAt":"2026-10-01T08:00:00.000Z",
         "updatedBy":{"id":"p1","name":"Gideon"},"updatedAt":"2026-10-01T08:00:00.000Z"}
        """
    }

    private static func outing(_ json: String) throws -> Outing {
        try APIClient.decoder.decode(Outing.self, from: Data(json.utf8))
    }

    private func status(_ json: String) throws -> OutingStatus {
        try Self.outing(json).status(now: Self.now, calendar: Self.amsterdam)
    }

    @Test func everyOutingSaysOneSentenceAboutItsState() throws {
        let tonight = try status(Self.outingJSON("a", "Stille Wateren", startsAt: "2026-10-22T18:00:00.000Z", venue: "De Kolenloods"))
        #expect(tonight == OutingStatus(text: "Vanavond · De Kolenloods", tone: .today))

        let lunch = try status(Self.outingJSON("b", "Lunchconcert", startsAt: "2026-10-22T10:30:00.000Z", venue: nil))
        #expect(lunch == OutingStatus(text: "Vandaag", tone: .today))

        let deadline = try status(Self.outingJSON(
            "c", "Foute Vrijdag XL", startsAt: "2026-11-20T20:30:00.000Z",
            tasks: [Self.task("k1", "Kaarten op naam zetten", due: "2026-10-27T00:00:00.000Z")]))
        #expect(deadline == OutingStatus(text: "Nog doen: kaarten op naam zetten", tone: .todo))

        let later = try status(Self.outingJSON(
            "d", "Neon Nineties", startsAt: "2027-05-13T19:00:00.000Z",
            tasks: [Self.task("k1", "Kaarten op naam zetten", due: "2027-04-29T00:00:00.000Z")]))
        #expect(later == OutingStatus(text: "Later: kaarten op naam zetten", tone: .later))

        let noTickets = try status(Self.outingJSON("e", "Zomerweide Festival", startsAt: "2027-06-18T10:00:00.000Z", tickets: 0))
        #expect(noTickets == OutingStatus(text: "Kaarten toevoegen", tone: .later))

        let soonWithoutTickets = try status(Self.outingJSON("f", "Halve Waarheden", startsAt: "2026-11-01T19:15:00.000Z", tickets: 0))
        #expect(soonWithoutTickets == OutingStatus(text: "Nog doen: kaarten toevoegen", tone: .todo))

        // A done item and the old calendar item say nothing.
        let settled = try status(Self.outingJSON(
            "g", "Halve Waarheden", startsAt: "2026-11-07T19:15:00.000Z",
            tasks: [Self.task("k1", "Oppas regelen", done: true), Self.task("k2", "In de agenda zetten", kind: "calendar")]))
        #expect(settled == OutingStatus(text: "Alles geregeld", tone: .done))

        let past = try status(Self.outingJSON("h", "Feest 40 jaar Mila", startsAt: "2026-10-03T18:00:00.000Z", tickets: 0))
        #expect(past.tone == .past)
    }

    @Test func theBadgeCountsUpcomingOutingsThatNeedSomethingNow() async throws {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/outings", json: "[" + [
            // An item within four weeks: counts.
            Self.outingJSON("a", "Foute Vrijdag XL", startsAt: "2026-11-20T20:30:00.000Z",
                            tasks: [Self.task("k1", "Kaarten op naam zetten", due: "2026-10-27T00:00:00.000Z")]),
            // No tickets ten days before: counts.
            Self.outingJSON("b", "Halve Waarheden", startsAt: "2026-11-01T19:15:00.000Z", tickets: 0),
            // An item months away: does not.
            Self.outingJSON("c", "Neon Nineties", startsAt: "2027-05-13T19:00:00.000Z",
                            tasks: [Self.task("k1", "Kaarten op naam zetten", due: "2027-04-29T00:00:00.000Z")]),
            // Settled, and long past: neither does.
            Self.outingJSON("d", "Stille Wateren", startsAt: "2026-12-01T19:00:00.000Z"),
            Self.outingJSON("e", "Feest 40 jaar Mila", startsAt: "2026-10-03T18:00:00.000Z", tickets: 0),
        ].joined(separator: ",") + "]")
        let model = model(server)
        await model.start()
        #expect(model.outings.count == 5)
        #expect(model.outingsNeedingAttention(now: Self.now) == 2)
    }

    @Test func theNewOutingSheetPostsWhatWhenAndWhere() async throws {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("POST", "/api/outings", status: 201, json: Self.outingJSON("n1", "Cabaret Theo Voorbeeld", startsAt: "2026-11-08T19:15:00.000Z"))
        let model = model(server)
        await model.start()
        let startsAt = try #require(APIClient.isoFractional.date(from: "2026-11-08T19:15:00.000Z"))

        let created = await model.createOuting(title: " Cabaret Theo Voorbeeld ", startsAt: startsAt, venue: "Stadsschouwburg Voorbeeld")
        let body = try #require(server.requests("POST", "/api/outings").last)
        #expect(body.contains(#""title":"Cabaret Theo Voorbeeld""#))
        #expect(body.contains(#""startsAt":"2026-11-08T19:15:00.000Z""#))
        #expect(body.contains(#""venue":"Stadsschouwburg Voorbeeld""#))
        // Who goes is everyone unless someone changes it.
        #expect(!body.contains("attendeeIds"))
        #expect(created?.id == "n1")
        #expect(model.selectedOutingId == "n1")
        #expect(model.outings.map(\.id) == ["n1"])
    }

    @Test func tickingAnItemUpdatesTheOutingEverywhere() async throws {
        let open = Self.outingJSON("o1", "Foute Vrijdag XL", startsAt: "2026-11-20T20:30:00.000Z", tasks: [Self.task("k1", "Oppas regelen")])
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/outings", json: "[\(open)]")
        server.on("PATCH", "/api/outings/o1/tasks/k1", json: Self.outingJSON(
            "o1", "Foute Vrijdag XL", startsAt: "2026-11-20T20:30:00.000Z", tasks: [Self.task("k1", "Oppas regelen", done: true)]))
        let model = model(server)
        await model.start()
        let task = try #require(model.outings.first?.checklist.first)

        await model.setTask(task, done: true, in: "o1")
        #expect(server.requests("PATCH", "/api/outings/o1/tasks/k1") == [#"{"done":true}"#])
        #expect(model.outings.first?.checklist.first?.done == true)
        #expect(model.outings.first?.checklist.first?.doneBy?.name == "Eva")
    }

    @Test func clickingAPersonInWieTogglesThem() async throws {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/outings", json: "[\(Self.outingJSON("o1", "Stille Wateren", startsAt: "2026-12-01T19:00:00.000Z"))]")
        server.on("PATCH", "/api/outings/o1", json: Self.outingJSON("o1", "Stille Wateren", startsAt: "2026-12-01T19:00:00.000Z")
            .replacingOccurrences(of: #",{"id":"p2","name":"Eva"}"#, with: ""))
        let model = model(server)
        await model.start()
        let outing = try #require(model.outings.first)

        await model.toggleAttendee(Person(id: "p2", name: "Eva"), in: outing)
        #expect(server.requests("PATCH", "/api/outings/o1") == [#"{"attendeeIds":["p1"]}"#])
        #expect(model.outings.first?.attendees.map(\.name) == ["Gideon"])

        await model.toggleAttendee(Person(id: "p3", name: "Mila"), in: try #require(model.outings.first))
        #expect(server.requests("PATCH", "/api/outings/o1").last == #"{"attendeeIds":["p1","p3"]}"#)
    }

    @Test func aChangeOnTheOtherMacReloadsTheList() async throws {
        let one = Self.outingJSON("o1", "Stille Wateren", startsAt: "2026-12-01T19:00:00.000Z")
        let two = Self.outingJSON("o2", "Neon Nineties", startsAt: "2027-05-13T19:00:00.000Z")
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/outings", json: "[\(one)]")
        let model = model(server)
        await model.start()
        model.selection = .outings
        await model.selectionLoad?.value
        #expect(model.outings.map(\.id) == ["o1"])
        #expect(model.selectedOutingId == "o1")

        server.on("GET", "/api/outings", json: "[\(one),\(two)]")
        await model.handle(ServerEvent(type: "outing.changed", fields: ["outingId": "o2"]))
        #expect(model.outings.map(\.id) == ["o1", "o2"])
        #expect(model.selectedOutingId == "o1")
    }

    @Test func theMacRemindsOnlyOfOutingsItsPersonGoesTo() async throws {
        let mine = Self.outingJSON("o1", "Stille Wateren", startsAt: "2026-12-01T19:00:00.000Z")
        let evasOnly = Self.outingJSON("o2", "Yoga-avond", startsAt: "2026-12-02T19:00:00.000Z")
            .replacingOccurrences(of: #""attendees":[{"id":"p1","name":"Gideon"},"#, with: #""attendees":["#)
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/outings", json: "[\(mine),\(evasOnly)]")
        let model = model(server)
        await model.start()
        #expect(Set(model.outingReminders(now: Self.now).map(\.outingId)) == ["o1"])
    }

    @Test func theMacRemindsOnTheDayAndBeforeADeadline() throws {
        let outing = try Self.outing(Self.outingJSON(
            "o1", "Foute Vrijdag XL", startsAt: "2026-11-20T20:30:00.000Z",
            tasks: [Self.task("k1", "Kaarten op naam zetten", due: "2026-11-13T00:00:00.000Z")]))
        let reminders = outing.reminders(now: Self.now, calendar: Self.amsterdam)
        let day = try #require(reminders.first { $0.id == "outing.o1.day" })
        #expect(day.title == "Vanavond: Foute Vrijdag XL")
        #expect(day.body == "21:30 · Voorbeeldhal")
        #expect(day.fireAt == APIClient.isoFractional.date(from: "2026-11-20T08:00:00.000Z"))
        // Four weeks before has passed; one week before is still ahead.
        let deadline = reminders.filter { $0.id.contains(".task.") }
        #expect(deadline.map(\.title) == ["Kaarten op naam zetten voor Foute Vrijdag XL, nog 7 dagen"])
        #expect(deadline.first?.fireAt == APIClient.isoFractional.date(from: "2026-11-06T08:00:00.000Z"))
    }
}
