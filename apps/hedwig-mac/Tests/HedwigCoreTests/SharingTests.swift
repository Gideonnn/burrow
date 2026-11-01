import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite(.serialized) struct SharingTests {
    private func model(_ server: MockServer) -> AppModel {
        let client = server.client()
        return AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
    }

    private func with(_ json: String, _ extra: String) -> String {
        json.replacingOccurrences(of: #""bodyHtml":null}"#, with: #""bodyHtml":null,\#(extra)}"#)
    }

    private func serve(_ server: MockServer) {
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/people", json: #"[{"id":"p1","name":"Gideon"},{"id":"p2","name":"Angela"}]"#)
    }

    @Test func decodesWhoSharesAMailAndStillReadsOldServers() throws {
        let json = with(Fixture.message("m1", subject: "Energie"), #""share":{"by":"p2","with":["p1"]},"shareSuggestion":null"#)
        let message = try APIClient.decoder.decode(MessageSummary.self, from: Data(json.utf8))
        #expect(message.share == MessageShare(by: "p2", with: ["p1"]))
        let old = try APIClient.decoder.decode(MessageSummary.self, from: Data(Fixture.message("m2", subject: "Oud").utf8))
        #expect(old.share == nil)
        #expect(old.shareSuggestion == nil)
    }

    @Test func opensMailSharedWithMeWithoutTouchingIt() async throws {
        let server = MockServer()
        serve(server)
        let shared = with(Fixture.message("m1", subject: "Huur", mailbox: "mb9"), #""share":{"by":"p2","with":["p1"]}"#)
        let suggested = with(Fixture.message("m2", subject: "Energie"), #""shareSuggestion":{"reason":"energierekening"}"#)
        let mine = with(Fixture.message("m3", subject: "Texel"), #""share":{"by":null,"with":["p2"]}"#)
        server.on("GET", "/api/share/suggestions", json: #"{"suggestions":[{"message":\#(suggested),"reason":"energierekening"}]}"#)
        server.on("GET", "/api/shared", json: #"{"withMe":[\#(shared)],"byMe":[\#(mine)]}"#)
        server.on("GET", "/api/messages/m1", json: shared)
        let model = model(server)
        await model.start()
        model.selection = .shared
        await model.selectionLoad?.value
        await model.messageLoad?.value

        #expect(model.messages.map(\.id) == ["m2", "m1", "m3"])
        model.selectedMessageId = "m1"
        await model.messageLoad?.value
        #expect(model.detail?.id == "m1")
        #expect(model.detailIsMine == false)
        #expect(model.personName("p2") == "Angela")
        #expect(server.requests("POST", "/api/messages/m1/actions").isEmpty)
    }

    @Test func sharesTheOpenMailWithTheHousemateAndTakesItBack() async throws {
        let server = MockServer()
        serve(server)
        let plain = Fixture.message("m1", subject: "Energie", unread: false)
        let shared = with(plain, #""share":{"by":null,"with":["p2"]}"#)
        server.on("GET", "/api/mailboxes/mb1/messages", json: "[\(plain)]")
        server.on("GET", "/api/messages/m1", json: plain)
        server.on("POST", "/api/messages/m1/share", json: shared)
        server.on("DELETE", "/api/messages/m1/share/p2", json: plain)
        let model = model(server)
        await model.start()
        await model.loadPeople()
        model.selection = .inbox(mailboxId: "mb1")
        await model.selectionLoad?.value
        await model.messageLoad?.value
        #expect(model.housematesTitle == "Angela")

        await model.toggleShare()
        #expect(server.requests("POST", "/api/messages/m1/share") == [#"{"personId":"p2"}"#])
        server.on("GET", "/api/messages/m1", json: shared)
        await model.openSelected()
        await model.toggleShare()
        #expect(server.requests("DELETE", "/api/messages/m1/share/p2").count == 1)
    }
}
