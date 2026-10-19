import Foundation
import Testing
@testable import HedwigCore

@Suite struct ModelTests {
    @Test func decodesServerDatesWithAndWithoutFractions() throws {
        let json = #"[{"id":"r1","text":"Keep mail from a@example.com","createdAt":"2026-10-19T09:41:00.123Z"},{"id":"r2","text":"x","createdAt":"2026-10-19T09:41:00Z"}]"#
        let rules = try APIClient.decoder.decode([LearnedRule].self, from: Data(json.utf8))
        #expect(rules.count == 2)
        #expect(rules[0].createdAt.timeIntervalSince(rules[1].createdAt) < 1)
    }

    @Test func encodesServerOpsInTheContractShape() throws {
        let data = try JSONEncoder().encode([ServerOp.archive, .addLabel("Bon")])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#"{"op":"archive"}"#))
        #expect(json.contains(#""label":"Bon""#))
        #expect(try JSONDecoder().decode([ServerOp].self, from: data) == [.archive, .addLabel("Bon")])
    }

    @Test func parsesAndFormatsAddressLists() {
        let list = Address.parseList("Marieke de Vries <marieke@example.nl>, bas@example.nl")
        #expect(list == [Address(name: "Marieke de Vries", email: "marieke@example.nl"), Address(email: "bas@example.nl")])
        #expect(Address.format(list) == "Marieke de Vries <marieke@example.nl>, bas@example.nl")
    }
}

@Suite struct SSEParserTests {
    @Test func turnsEventAndDataLinesIntoEvents() {
        var parser = SSEParser()
        #expect(parser.feed("event: message.new") == nil)
        #expect(parser.feed(#"data: {"type":"message.new","mailboxId":"mb1","messageId":"m9"}"#) == nil)
        #expect(parser.feed("") == ServerEvent(type: "message.new", mailboxId: "mb1", messageId: "m9"))
        #expect(parser.feed("") == nil)
    }
}

@MainActor
@Suite(.serialized) struct AppModelTests {
    private func model(_ server: MockServer) -> AppModel {
        let client = server.client()
        return AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
    }

    private func server() -> MockServer {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/filtered", json: "[]")
        server.on("GET", "/api/drafts", json: "[]")
        server.on("GET", "/api/mailboxes/mb1/messages", json: "[\(Fixture.message("m1", subject: "Eerste")),\(Fixture.message("m2", subject: "Tweede"))]")
        server.on("GET", "/api/messages/m1", json: Fixture.message("m1", subject: "Eerste"))
        server.on("GET", "/api/messages/m2", json: Fixture.message("m2", subject: "Tweede"))
        server.on("POST", "/api/messages/m1/actions", json: Fixture.message("m1", subject: "Eerste", folder: "archive", unread: false))
        return server
    }

    @Test func archivingRemovesTheMessageAndSelectsTheNext() async throws {
        let server = server()
        let model = model(server)
        model.selection = .inbox(mailboxId: "mb1")
        await model.loadSelection()
        #expect(model.selectedMessageId == "m1")

        await model.perform([.archive], on: "m1")
        #expect(model.messages.map(\.id) == ["m2"])
        #expect(model.selectedMessageId == "m2")
        #expect(server.requests("POST", "/api/messages/m1/actions").first?.contains(#""op":"archive""#) == true)
    }

    @Test func openingAnUnreadMessageMarksItReadAtTheServer() async throws {
        let server = server()
        server.on("POST", "/api/messages/m1/actions", json: Fixture.message("m1", subject: "Eerste", unread: false))
        let model = model(server)
        await model.start()
        model.selection = .inbox(mailboxId: "mb1")
        await model.loadSelection()
        await model.openSelected()
        #expect(model.detail?.unread == false)
        #expect(model.messages.first?.unread == false)
    }

    @Test func replyAddressesTheSenderAndQuotesTheMessage() async throws {
        let server = server()
        let model = model(server)
        await model.start()
        model.selection = .inbox(mailboxId: "mb1")
        await model.loadSelection()
        await model.openSelected()
        let reply = try #require(model.reply())
        #expect(reply.to == "Marieke <marieke@example.nl>")
        #expect(reply.subject == "Re: Eerste")
        #expect(reply.inReplyTo == "m1")
        #expect(reply.body.contains("> Zin in eten?"))
    }

    @Test func aRevokedKeyDisconnects() async throws {
        let server = MockServer()
        server.on("GET", "/api/me", status: 401, json: #"{"error":"missing or invalid API key"}"#)
        let model = model(server)
        await model.start()
        #expect(model.connection == nil)
        #expect(model.error != nil)
    }
}
