import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite(.serialized) struct SpamReviewTests {
    private func model(_ server: MockServer) -> AppModel {
        let client = server.client()
        return AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
    }

    private static func entry(_ id: String, message: String, unsure: Bool) -> String {
        #"{"id":"\#(id)","bot":"Kreacher","action":{"kind":"spam"},"reason":"Onbekende afzender.","unsure":\#(unsure),"serverOps":["label SPAM"],"createdAt":"2026-10-19T09:41:00.000Z","message":\#(message)"#
            + "}"
    }

    private func server() -> MockServer {
        let server = MockServer()
        let old = Fixture.message("s1", subject: "Oud", folder: "spam", at: "2026-10-18T09:00:00.000Z")
        let sure = Fixture.message("s2", subject: "Zeker", folder: "spam", at: "2026-10-19T09:00:00.000Z")
        let doubt = Fixture.message("s3", subject: "Twijfel", folder: "spam", at: "2026-10-17T09:00:00.000Z")
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/drafts", json: "[]")
        server.on("GET", "/api/mailboxes/mb1/messages", json: "[\(sure),\(old),\(doubt)]")
        server.on("GET", "/api/filtered", json: "[\(Self.entry("e3", message: doubt, unsure: true)),\(Self.entry("e2", message: sure, unsure: false))]")
        server.on("GET", "/api/messages/s1", json: old)
        server.on("GET", "/api/messages/s3", json: doubt)
        return server
    }

    @Test func spamShowsTheBotsChoicesFirstUnsureOnTop() async throws {
        let model = model(server())
        await model.start()
        try await model.show("spam")
        #expect(model.selection == .folder(.spam, mailboxId: "mb1"))
        #expect(model.messages.map(\.subject) == ["Twijfel", "Zeker", "Oud"])
        #expect(model.review(for: "s3")?.unsure == true)
        #expect(model.review(for: "s1") == nil)
        #expect(model.reviewCount(mailboxId: "mb1") == 2)
    }

    @Test func openingSpamLeavesItUnread() async throws {
        let server = server()
        let model = model(server)
        await model.start()
        try await model.show("spam")
        try await model.open(messageId: "s1")
        #expect(model.detail?.unread == true)
        #expect(server.requests("POST", "/api/messages/s1/actions").isEmpty)
    }

    @Test func spamNeverLoadsRemoteImages() async throws {
        let model = model(server())
        await model.start()
        try await model.show("spam")
        try await model.open(messageId: "s1")
        #expect(model.detail?.mayLoadRemoteImages == false)
    }

    @Test func notSpamRestoresTheEntryAndLeavesTheList() async throws {
        let server = server()
        server.on("POST", "/api/filtered/e3/restore", json: #"{"restored":true}"#)
        let model = model(server)
        await model.start()
        try await model.show("spam")
        let entry = try #require(model.review(for: "s3"))
        await model.restore(entry)
        #expect(server.requests("POST", "/api/filtered/e3/restore").count == 1)
        #expect(!model.messages.contains { $0.id == "s3" })
    }

    @Test func notSpamWithoutAnEntryMovesItToTheInboxAsRead() async throws {
        let server = server()
        server.on("POST", "/api/messages/s1/actions", json: Fixture.message("s1", subject: "Oud", unread: false))
        let model = model(server)
        await model.start()
        try await model.show("spam")
        try await model.open(messageId: "s1")
        await model.notSpam()
        let sent = try #require(server.requests("POST", "/api/messages/s1/actions").first)
        #expect(sent.contains(#""op":"moveToInbox""#) && sent.contains(#""op":"markRead""#))
        #expect(!model.messages.contains { $0.id == "s1" })
    }
}
