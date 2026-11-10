import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite struct ComposeTests {
    @Test func savingAnEditedDraftReplacesTheOneItCameFrom() async throws {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/drafts", json: "[]")
        server.on(
            "POST", "/api/drafts",
            json: #"{"id":"d2","mailboxId":"mb1","createdBy":"MacBook Gideon","to":[{"email":"bas@example.nl"}],"cc":[],"subject":"Hoi","body":"Tot morgen","createdAt":"2026-11-11T09:00:00Z"}"#)
        server.on("DELETE", "/api/drafts/d1", json: "{}")
        let client = server.client()
        let model = AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
        await model.start()

        let draft = ComposeDraft(mailboxId: "mb1", to: "bas@example.nl", subject: "Hoi", body: "Tot morgen", serverDraftId: "d1")
        try await model.saveDraft(draft)
        #expect(server.requests("POST", "/api/drafts").first?.contains(#""subject":"Hoi""#) == true)
        #expect(server.requests("DELETE", "/api/drafts/d1").count == 1)
    }
}
