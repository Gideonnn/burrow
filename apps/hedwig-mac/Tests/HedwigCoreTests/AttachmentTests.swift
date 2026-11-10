import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite struct AttachmentTests {
    @Test func listsFilesAndKeepsOneOnDiskUnderItsOwnName() async throws {
        // A fresh id: the file stays in the temporary folder between runs.
        let id = "m-\(UUID().uuidString)"
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on(
            "GET", "/api/messages/\(id)/attachments",
            json: #"[{"id":"a1","name":"../factuur maart.pdf","contentType":"application/pdf","size":5,"inline":false},{"id":"a2","name":"logo.png","contentType":"image/png","size":9,"inline":true}]"#)
        server.onData("GET", "/api/messages/\(id)/attachments/a1", Data("%PDF-".utf8))
        let client = server.client()
        let model = AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))

        let files = await model.attachments(messageId: id)
        #expect(files.map(\.name) == ["../factuur maart.pdf"])

        let url = try #require(await model.attachmentFile(files[0], messageId: id))
        #expect(url.lastPathComponent == "factuur maart.pdf")
        #expect(try Data(contentsOf: url) == Data("%PDF-".utf8))
        #expect(server.requests("GET", "/api/messages/\(id)/attachments/a1").count == 1)

        _ = await model.attachmentFile(files[0], messageId: id)
        #expect(server.requests("GET", "/api/messages/\(id)/attachments/a1").count == 1)
    }
}
