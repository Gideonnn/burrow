import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite(.serialized) struct RoleTests {
    private func model(_ server: MockServer) -> AppModel {
        let client = server.client()
        return AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
    }

    private func server() -> MockServer {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.household)
        server.on("GET", "/api/filtered", json: "[]")
        server.on("GET", "/api/drafts", json: "[]")
        server.on("GET", "/api/mailboxes/mb1/messages", json: "[]")
        server.on("GET", "/api/mailboxes/w1/messages", json: "[\(Fixture.message("a", subject: "Oud", mailbox: "w1", at: "2026-10-18T09:00:00.000Z"))]")
        server.on("GET", "/api/mailboxes/w2/messages", json: "[\(Fixture.message("b", subject: "Nieuw", mailbox: "w2", at: "2026-10-19T09:00:00.000Z"))]")
        return server
    }

    @Test func mailboxesAreGroupedByRole() async throws {
        let model = model(server())
        await model.start()
        #expect(model.mailboxGroups.map(\.role) == [.private, .work])
        #expect(model.mailboxGroups.last?.mailboxes.map(\.name) == ["Werk", "Klant"])
    }

    @Test func draggingAMailboxReordersItsRoleAndSavesEveryMailbox() async throws {
        let server = server()
        server.on("PUT", "/api/mailboxes/order", status: 204, json: "")
        let model = model(server)
        await model.start()
        await model.moveMailboxes(in: .work, from: [1], to: 0)
        #expect(model.mailboxGroups.last?.mailboxes.map(\.name) == ["Klant", "Werk"])
        #expect(server.requests("PUT", "/api/mailboxes/order").first == #"{"ids":["mb1","w2","w1"]}"#)
    }

    @Test func aRoleOpensTheInboxOfItsFirstMailbox() async throws {
        let model = model(server())
        await model.start()
        try await model.show("work")
        #expect(model.selection == .inbox(mailboxId: "w1"))
        #expect(model.messages.map(\.subject) == ["Oud"])
        try await model.show("school")
        #expect(model.selection == .inbox(mailboxId: "mb1"))
    }

    @Test func renamingAMailboxShowsAtOnce() async throws {
        let server = server()
        server.on("PATCH", "/api/mailboxes/w1", json: #"{"id":"w1","ownerId":"p1","provider":"gmail","address":"gideon@werk.example","name":"Colloport","role":"work"}"#)
        let model = model(server)
        await model.start()
        try await model.updateMailbox("w1", name: "Colloport", role: .work)
        #expect(model.mailbox("w1")?.name == "Colloport")
        #expect(server.requests("PATCH", "/api/mailboxes/w1").first?.contains(#""name":"Colloport""#) == true)
    }

    @Test func mailboxInstructionsAndTheLanguageAreSaved() async throws {
        let server = server()
        server.on("PATCH", "/api/mailboxes/w1", json: #"{"id":"w1","ownerId":"p1","provider":"gmail","address":"gideon@werk.example","name":"Werk","role":"work","instructions":"Nooit klantmail archiveren."}"#)
        server.on("PATCH", "/api/me", json: #"{"language":"Dutch"}"#)
        let model = model(server)
        await model.start()
        try await model.updateMailbox("w1", instructions: "Nooit klantmail archiveren.")
        #expect(model.mailbox("w1")?.instructions == "Nooit klantmail archiveren.")
        try await model.setLanguage("Dutch")
        #expect(model.me?.language == "Dutch")
        #expect(server.requests("PATCH", "/api/me").first?.contains(#""language":"Dutch""#) == true)
    }
}
