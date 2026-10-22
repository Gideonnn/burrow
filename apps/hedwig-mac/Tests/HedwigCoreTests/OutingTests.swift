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
}
