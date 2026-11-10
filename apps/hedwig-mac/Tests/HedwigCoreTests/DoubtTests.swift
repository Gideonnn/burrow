import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite(.serialized) struct DoubtTests {
    private func model(_ server: MockServer) -> AppModel {
        let client = server.client()
        return AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
    }

    nonisolated private static let doubtful = Fixture.message("i1", subject: "Aanbieding")
    nonisolated private static let normal = Fixture.message("i2", subject: "Etentje")
    nonisolated private static let doubt =
        #"{"id":"d1","bot":"kreacher","action":{"kind":"spam"},"reason":"Onbekende winkel.","unsure":true,"serverOps":[],"createdAt":"2026-10-19T09:41:00.000Z","message":\#(doubtful)}"#

    /// The doubt list empties once the person answered, as on the server.
    private func server(answered: @escaping @Sendable () -> Bool = { false }) -> MockServer {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/drafts", json: "[]")
        server.on("GET", "/api/filtered", json: "[]")
        server.on("GET", "/api/doubts") { _ in (200, answered() ? "[]" : "[\(Self.doubt)]") }
        server.on("GET", "/api/mailboxes/mb1/messages", json: "[\(Self.doubtful),\(Self.normal)]")
        server.on("GET", "/api/messages/i1", json: Self.doubtful)
        server.on("GET", "/api/messages/i2", json: Self.normal)
        return server
    }

    @Test func aDoubtMarksItsMessage() async throws {
        let model = model(server())
        await model.start()
        #expect(model.doubt(for: "i1")?.reason == "Onbekende winkel.")
        #expect(model.doubt(for: "i2") == nil)
    }

    @Test func aDoubtNeverLoadsRemoteImagesUnasked() async throws {
        let model = model(server())
        await model.start()
        try await model.open(messageId: "i1")
        #expect(model.loadsRemoteImagesUnasked(try #require(model.detail)) == false)
        try await model.open(messageId: "i2")
        #expect(model.loadsRemoteImagesUnasked(try #require(model.detail)) == true)
    }

    @Test func spamNeverLoadsRemoteImagesUnasked() async throws {
        let server = server()
        let spam = Fixture.message("s1", subject: "Spam", folder: "spam")
        server.on("GET", "/api/mailboxes/mb1/messages", json: "[\(spam)]")
        server.on("GET", "/api/messages/s1", json: spam)
        let model = model(server)
        await model.start()
        try await model.open(messageId: "s1")
        #expect(model.loadsRemoteImagesUnasked(try #require(model.detail)) == false)
    }

    @Test func answeringSpamMovesItOutOfTheInbox() async throws {
        let answered = Flag(false)
        let server = server(answered: { answered.value })
        server.on("POST", "/api/doubts/d1/spam") { _ in
            answered.value = true
            return (200, #"{"settled":true}"#)
        }
        let model = model(server)
        await model.start()
        let entry = try #require(model.doubt(for: "i1"))
        await model.settle(entry, spam: true)
        #expect(server.requests("POST", "/api/doubts/d1/spam").count == 1)
        #expect(!model.messages.contains { $0.id == "i1" })
        #expect(model.doubt(for: "i1") == nil)
    }

    @Test func answeringNotSpamKeepsItInTheInbox() async throws {
        let answered = Flag(false)
        let server = server(answered: { answered.value })
        server.on("POST", "/api/doubts/d1/not-spam") { _ in
            answered.value = true
            return (200, #"{"settled":true}"#)
        }
        let model = model(server)
        await model.start()
        let entry = try #require(model.doubt(for: "i1"))
        await model.settle(entry, spam: false)
        #expect(server.requests("POST", "/api/doubts/d1/not-spam").count == 1)
        #expect(model.messages.contains { $0.id == "i1" })
        #expect(model.doubt(for: "i1") == nil)
    }

    @Test func markingADoubtAsSpamByHandSettlesIt() async throws {
        let answered = Flag(false)
        let server = server(answered: { answered.value })
        server.on("POST", "/api/messages/i1/actions") { _ in
            answered.value = true
            return (200, Fixture.message("i1", subject: "Aanbieding", folder: "spam"))
        }
        let model = model(server)
        await model.start()
        model.selectedMessageId = "i1"
        await model.perform([.moveToSpam])
        #expect(model.doubt(for: "i1") == nil)
    }

    @Test func learnedRulesReadAsSpamOrNotSpam() async throws {
        let server = server()
        server.on(
            "GET", "/api/rules",
            json: #"""
                [{"id":"r1","text":"x","kind":"spam","sender":"news.example.com","createdAt":"2026-10-19T09:41:00.000Z"},
                 {"id":"r2","text":"y","kind":"not-spam","sender":"shop@example.com","createdAt":"2026-10-19T09:41:00.000Z"},
                 {"id":"r3","text":"Keep mail from a@example.com in the inbox.","createdAt":"2026-10-19T09:41:00.000Z"}]
                """#)
        let rules = try await server.client().rules()
        #expect(rules.map(\.label) == [
            "Spam: news.example.com",
            "Geen spam: shop@example.com",
            "Keep mail from a@example.com in the inbox.",
        ])
    }
}
