import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite(.serialized) struct SelectionTests {
    private func model(_ server: MockServer) -> AppModel {
        let client = server.client()
        return AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"),
            defaults: UserDefaults(suiteName: "hedwig.selection.tests")!)
    }

    private func server() -> MockServer {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/filtered", json: "[]")
        server.on("GET", "/api/drafts", json: "[]")
        server.on("GET", "/api/mailboxes/counts", json: "[]")
        server.on(
            "GET", "/api/mailboxes/mb1/messages",
            json: "[\(Fixture.message("m1", subject: "Een")),\(Fixture.message("m2", subject: "Twee", unread: false)),\(Fixture.message("m3", subject: "Drie"))]")
        for id in ["m1", "m2", "m3"] {
            server.on("GET", "/api/messages/\(id)", json: Fixture.message(id, subject: id))
        }
        return server
    }

    private func loaded(_ server: MockServer) async -> AppModel {
        let model = model(server)
        await model.start()
        model.selection = .inbox(mailboxId: "mb1")
        await model.selectionLoad?.value
        await model.messageLoad?.value
        return model
    }

    @Test func severalSelectedOpenNoneAndMarkNoneRead() async {
        let server = server()
        let model = await loaded(server)
        let marksBefore = server.requests("POST", "/api/messages/m3/actions").count

        model.selectedMessageIds = ["m2", "m3"]
        await model.messageLoad?.value
        #expect(model.selectedMessageId == nil)
        #expect(model.detail == nil)
        #expect(server.requests("POST", "/api/messages/m3/actions").count == marksBefore)

        model.selectedMessageId = "m3"
        #expect(model.selectedMessageIds == ["m3"])
    }

    @Test func archivingASelectionMovesEveryMessageAndSelectsTheNext() async {
        let server = server()
        server.on("POST", "/api/messages/m1/actions", json: Fixture.message("m1", subject: "Een", folder: "archive"))
        server.on("POST", "/api/messages/m2/actions", json: Fixture.message("m2", subject: "Twee", folder: "archive"))
        let model = await loaded(server)

        model.selectedMessageIds = ["m1", "m2"]
        #expect(model.canOrganizeSelection)
        #expect(!model.canReply)
        await model.perform([.archive])
        #expect(model.messages.map(\.id) == ["m3"])
        #expect(model.selectedMessageIds == ["m3"])
        #expect(server.requests("POST", "/api/messages/m2/actions").first?.contains(#""op":"archive""#) == true)
    }

    @Test func markingASelectionReadWhenAnyIsUnread() async {
        let server = server()
        server.on("POST", "/api/messages/m2/actions", json: Fixture.message("m2", subject: "Twee", unread: false))
        server.on("POST", "/api/messages/m3/actions", json: Fixture.message("m3", subject: "Drie", unread: false))
        let model = await loaded(server)

        await model.toggleRead(["m2", "m3"])
        #expect(server.requests("POST", "/api/messages/m2/actions").last?.contains(#""op":"markRead""#) == true)
        #expect(server.requests("POST", "/api/messages/m3/actions").last?.contains(#""op":"markRead""#) == true)
    }

    @Test func dropsMoveMailOnlyWithinItsOwnMailbox() async {
        let server = server()
        server.on("POST", "/api/messages/m3/actions", json: Fixture.message("m3", subject: "Drie", folder: "spam"))
        let model = await loaded(server)

        #expect(model.canMove(["m3"], to: .folder(.spam, mailboxId: "mb1")))
        #expect(!model.canMove(["m3"], to: .folder(.spam, mailboxId: "other")))
        #expect(!model.canMove(["m3"], to: .inbox(mailboxId: "mb1")))
        #expect(!model.canMove(["m3"], to: .tasks))

        await model.move(["m3"], to: .folder(.spam, mailboxId: "mb1"))
        #expect(server.requests("POST", "/api/messages/m3/actions").last?.contains(#""op":"moveToSpam""#) == true)
        #expect(!model.messages.contains { $0.id == "m3" })
    }

    @Test func placesSurviveAsTextAndAGoneMailboxFallsBack() async {
        for place: SidebarItem in [.inbox(mailboxId: "mb1"), .folder(.archive, mailboxId: "mb1"), .drafts(mailboxId: "mb1"), .tasks, .shared] {
            #expect(SidebarItem(storageKey: place.storageKey) == place)
        }
        #expect(SidebarItem(storageKey: "nonsense") == nil)

        let model = model(server())
        model.selection = .folder(.archive, mailboxId: "gone")
        await model.start()
        #expect(model.selection == .inbox(mailboxId: "mb1"))
    }
}
