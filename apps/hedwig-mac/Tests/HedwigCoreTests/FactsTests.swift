import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite(.serialized) struct FactsTests {
    private func model(_ server: MockServer) -> AppModel {
        let client = server.client()
        return AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
    }

    @Test func decodesFactsAndShowsTheCategoryInDutch() throws {
        let json = Fixture.message("m1", subject: "Je factuur").replacingOccurrences(
            of: #""bodyHtml":null}"#,
            with: #""bodyHtml":null,"facts":{"category":"invoice","priority":"high","summary":"Factuur van de tandarts, € 80","sensitive":true,"sensitiveKinds":["iban"],"people":[],"organisations":["Tandarts Example"],"amounts":[{"value":80,"currency":"EUR"}],"dates":["2026-11-01"],"keywords":["tandarts"],"source":"model"}}"#)
        let message = try APIClient.decoder.decode(MessageSummary.self, from: Data(json.utf8))
        #expect(message.facts?.categoryTitle == "Factuur")
        #expect(message.facts?.sensitive == true)
        #expect(message.facts?.amounts?.first?.value == 80)
        let old = try APIClient.decoder.decode(MessageSummary.self, from: Data(Fixture.message("m2", subject: "Oud").utf8))
        #expect(old.facts == nil)
    }

    @Test func showsCodesInSearchOnlyWhenAsked() async throws {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/mailboxes/mb1/messages", json: "[]")
        server.on("GET", "/api/search", json: #"{"explanation":null,"results":[]}"#)
        server.on("POST", "/api/search/ai", json: #"{"explanation":"Codes","results":[]}"#)
        let model = model(server)
        model.selection = .inbox(mailboxId: "mb1")
        model.searchText = "netflix"
        await model.searchLoad?.value
        #expect(server.queries("GET", "/api/search").last?.contains("includeLow") == false)

        model.searchIncludesLow = true
        await model.searchLoad?.value
        #expect(server.queries("GET", "/api/search").last?.contains("includeLow=true") == true)

        await model.searchWithAI()
        #expect(server.requests("POST", "/api/search/ai").last?.contains(#""includeLow":true"#) == true)
    }

    @Test func saysWhatThisMacsRunnerDoes() async throws {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        let name = RunnerConfig.load().name
        server.on("GET", "/api/runners", json: """
        {"runners":[{"id":"r1","name":"\(name)","personName":"Gideon","mine":true,"queues":["local"],"agents":[],
          "models":["ollama:gemma4:26b-a4b"],"kinds":["*"],"paused":false,"online":true,"lastSeenAt":null,"doing":"Mail-facts"},
          {"id":"server","name":"server","personName":null,"mine":false,"queues":["cloud"],"agents":["claude"],"models":[],
          "kinds":["*"],"paused":false,"online":true,"lastSeenAt":null,"doing":null}],
         "work":[]}
        """)
        server.on("PATCH", "/api/runners/r1", json: """
        {"id":"r1","name":"\(name)","personName":"Gideon","mine":true,"queues":["local"],"agents":[],"models":[],
         "kinds":["*"],"paused":true,"online":true,"lastSeenAt":null,"doing":null}
        """)
        let model = model(server)
        #expect(model.runnerStatus == "Geen runner op deze Mac")
        await model.start()
        await model.refreshRunners()
        #expect(model.thisMacRunners.map(\.id) == ["r1"])
        #expect(model.runnerStatus == "Mail-facts")

        await model.setRunner(model.thisMacRunners[0], paused: true)
        #expect(server.requests("PATCH", "/api/runners/r1").first == #"{"paused":true}"#)
    }

    @Test func makesAFactsOnlyKey() async throws {
        let server = MockServer()
        server.on("POST", "/api/admin/keys", json: """
        {"key":{"id":"k2","personId":"p1","name":"Codex","prefix":"bk_abc","rights":["read"],"mailboxIds":null,
          "factsOnly":true,"lastUsedAt":null,"revokedAt":null},"token":"bk_secret"}
        """)
        let created = try await server.client().createKey(personId: "p1", name: "Codex", rights: [.read], mailboxIds: nil, factsOnly: true)
        #expect(created.key.factsOnly == true)
        #expect(server.requests("POST", "/api/admin/keys").first?.contains(#""factsOnly":true"#) == true)
    }
}
