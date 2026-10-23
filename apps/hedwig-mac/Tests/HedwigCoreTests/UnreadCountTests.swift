import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite(.serialized) struct UnreadCountTests {
    private func model(_ server: MockServer) -> AppModel {
        let client = server.client()
        return AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
    }

    private static func counts(inbox: Int, unread: Int) -> String {
        #"[{"mailboxId":"mb1","folder":"inbox","total":\#(inbox),"unread":\#(unread)},{"mailboxId":"mb1","folder":"archive","total":900,"unread":3}]"#
    }

    // The list loads only the newest page; two messages stand in for it here.
    private func server() -> MockServer {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/filtered", json: "[]")
        server.on("GET", "/api/drafts", json: "[]")
        server.on("GET", "/api/mailboxes/mb1/messages", json: "[\(Fixture.message("m1", subject: "Eerste")),\(Fixture.message("m2", subject: "Tweede", unread: false))]")
        server.on("GET", "/api/mailboxes/counts", json: Self.counts(inbox: 340, unread: 212))
        server.on("POST", "/api/messages/m1/actions", json: Fixture.message("m1", subject: "Eerste", folder: "archive", unread: false))
        return server
    }

    @Test func sidebarAndHeaderShowTheServersCountNotTheLoadedPage() async {
        let model = model(server())
        await model.start()
        #expect(model.selection == .inbox(mailboxId: "mb1"))
        #expect(model.unreadCounts["mb1"] == 212)
        #expect(model.placeCount == (340, 212))
    }

    @Test func archivingRefreshesTheCount() async {
        let server = server()
        let model = model(server)
        await model.start()
        server.on("GET", "/api/mailboxes/counts", json: Self.counts(inbox: 339, unread: 211))
        await model.perform([.archive], on: "m1")
        #expect(model.unreadCounts["mb1"] == 211)
        #expect(model.placeCount == (339, 211))
    }

    @Test func aFolderUsesItsOwnCount() async throws {
        let model = model(server())
        await model.start()
        try await model.show("archive")
        #expect(model.placeCount == (900, 3))
    }
}
