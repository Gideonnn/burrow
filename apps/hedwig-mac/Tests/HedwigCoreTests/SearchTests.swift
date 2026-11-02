import BurrowKit
import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite struct SearchTests {
    private func server() -> MockServer {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/filtered", json: "[]")
        server.on("GET", "/api/drafts", json: "[]")
        server.on("GET", "/api/mailboxes/mb1/messages", json: "[\(Fixture.message("m1", subject: "Eerste"))]")
        server.on("GET", "/api/messages/m1", json: Fixture.message("m1", subject: "Eerste"))
        return server
    }

    private func model(_ server: MockServer) -> AppModel {
        let client = server.client()
        let model = AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
        model.embedQuestion = { _ in nil }
        return model
    }

    private static let jan = #"{"name":"Jan de Vries","emails":["jan@devries.example","jan@gmail.example"],"sent":12,"received":4,"lastAt":"2026-10-01T08:00:00.000Z","domain":false}"#

    @Test func offersPeopleAfterAnAtAndSearchesTheirMailOnceChosen() async throws {
        let server = server()
        server.on("GET", "/api/search/people", json: #"{"people":[\#(Self.jan)]}"#)
        server.on("GET", "/api/search", json: #"{"explanation":null,"results":[\#(Fixture.message("m9", subject: "Offerte website"))],"total":1}"#)
        let model = model(server)

        model.searchText = "offerte @ja"
        await model.suggestionLoad?.value
        #expect(server.queries("GET", "/api/search/people").last?.contains("q=ja") == true)
        let suggestion = try #require(model.searchSuggestions.first)
        #expect(suggestion.token.label == "Jan de Vries")
        #expect(suggestion.detail == "16× · jan@devries.example")

        // What the field does when the person picks the suggestion.
        model.searchTokens.append(suggestion.token)
        await Task.yield()
        #expect(model.searchText == "offerte ")
        #expect(model.searchSuggestions.isEmpty)
        await model.searchLoad?.value
        let query = try #require(server.queries("GET", "/api/search").last)
        #expect(query.contains("people=jan@devries.example,jan@gmail.example"))
        #expect(model.messages.map(\.subject) == ["Offerte website"])
    }

    @Test func turnsAMonthAKindAndAFlagIntoChips() {
        let now = ISO8601DateFormatter().date(from: "2026-11-02T08:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        #expect(SearchWords.period(for: "maart", now: now, calendar: calendar)
            == .period(key: "field:period", label: "maart 2026", after: "2026-03-01", before: "2026-04-01"))
        #expect(SearchWords.period(for: "december", now: now, calendar: calendar)?.label == "december 2025")
        #expect(SearchWords.period(for: "2024", now: now, calendar: calendar)
            == .period(key: "field:period", label: "2024", after: "2024-01-01", before: "2025-01-01"))
        #expect(SearchWords.period(for: "vorige week", now: now, calendar: calendar)?.label == "vorige week")
        #expect(SearchWords.period(for: "mar", now: now, calendar: calendar)?.label == "maart 2026")
        #expect(SearchWords.category(for: "facturen")?.label == "Facturen")
        #expect(SearchWords.flag(for: "bijlage") == .attachments(key: "field:attachments", label: "Met bijlage"))

        let suggestions = SearchWords.suggestions(for: "huur vorige maand", now: now)
        #expect(suggestions.first?.token.label == "vorige maand")
        #expect(suggestions.first?.text(after: "huur vorige maand") == "huur ")
        #expect(SearchWords.suggestions(for: "huur ", now: now).isEmpty)
    }

    @Test func marksWhereAResultMatched() {
        let hit = SearchHit(field: "body", text: "…neem jij de factuur mee? Café", ranges: [[13, 7], [26, 4]])
        let marked = hit.marked
        let bold = marked.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(marked[$0.range].characters) }
        #expect(bold == ["factuur", "Café"])
    }

    @Test func offersLensesFromWhatTheResultsHold() throws {
        let results = try APIClient.decoder.decode([MessageSummary].self, from: Data("""
        [\(Fixture.message("a", subject: "1", at: "2026-01-02T08:00:00.000Z")),\(Fixture.message("b", subject: "2", at: "2026-02-02T08:00:00.000Z")),
         \(Fixture.message("c", subject: "3", at: "2025-03-02T08:00:00.000Z")),\(Fixture.message("d", subject: "4", at: "2025-04-02T08:00:00.000Z"))]
        """.utf8))
        var mixed = results
        mixed[3].from = Address(name: "Studio Vos", email: "admin@vos.example")
        let lenses = SearchWords.lenses(for: mixed, own: ["gideon@example.com"], chosen: [])
        #expect(lenses.map(\.token.label) == ["Marieke", "2026", "2025"])
        #expect(lenses.map(\.count) == [3, 2, 2])
    }

    @Test func showsTheBotsPlanAsChipsReadsTheBestAndDropsAChipWithoutANewPlan() async throws {
        let server = server()
        let plan = #"{"groups":[["offerte"]],"people":["Jan"],"from":null,"after":null,"before":null,"folder":null,"roles":null,"unreadOnly":false,"hasAttachments":false,"categories":null,"includeLow":false,"answer":true,"explanation":"Offertes aan Jan"}"#
        let tokens = #"[{"key":"people:0","kind":"person","label":"Jan de Vries","emails":["jan@devries.example"]},{"key":"group:0","kind":"words","label":"offerte","words":["offerte"]}]"#
        server.on("POST", "/api/search/ai", json: """
        {"explanation":"Offertes aan Jan","results":[\(Fixture.message("m8", subject: "Oud")),\(Fixture.message("m9", subject: "Offerte website"))],
         "total":2,"tokens":\(tokens),"wantsAnswer":true,"plan":\(plan),"answer":null}
        """)
        server.on("POST", "/api/search/ai/rank", json: """
        {"results":[\(Fixture.message("m9", subject: "Offerte website")),\(Fixture.message("m8", subject: "Oud"))],"relevant":1,
         "answer":{"text":"De offerte was € 1.200.","messageIds":["m9"]}}
        """)
        let model = model(server)
        model.searchText = "wat kostte de offerte voor Jan?"
        await model.searchWithAI()

        #expect(model.planTokens.map(\.label) == ["Jan de Vries", "offerte"])
        #expect(model.messages.map(\.subject) == ["Offerte website", "Oud"])
        #expect(model.searchAnswer?.text == "De offerte was € 1.200.")
        #expect(model.selectedMessageId == "m9")
        #expect(server.requests("POST", "/api/search/ai/rank").first?.contains(#""answer":true"#) == true)

        let person = try #require(model.planTokens.first)
        model.removePlanToken(person)
        await model.searchLoad?.value
        let rerun = try #require(server.requests("POST", "/api/search/ai").last)
        #expect(rerun.contains(#""without":["people:0"]"#))
        #expect(rerun.contains(#""explanation":"Offertes aan Jan""#))
        #expect(server.requests("POST", "/api/search/ai/rank").count == 1)
        #expect(model.searchAnswer == nil)
    }

    @Test func sortsByBestOrNewest() async throws {
        let server = server()
        server.on("GET", "/api/search", json: """
        {"explanation":null,"results":[\(Fixture.message("old", subject: "Oud", at: "2025-01-01T08:00:00.000Z")),\(Fixture.message("new", subject: "Nieuw", at: "2026-10-01T08:00:00.000Z"))]}
        """)
        let model = model(server)
        model.searchText = "offerte"
        await model.searchLoad?.value
        #expect(model.messages.map(\.id) == ["old", "new"])
        model.searchSort = .newest
        #expect(model.messages.map(\.id) == ["new", "old"])
        model.searchSort = .best
        #expect(model.messages.map(\.id) == ["old", "new"])
    }
}

@MainActor
@Suite struct CancelTests {
    @Test func neverShowsACancelledRequestAsAnError() {
        let model = AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in MockServer().client() },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
        model.report(URLError(.cancelled))
        model.report(CancellationError())
        #expect(model.error == nil)
        model.report(URLError(.badServerResponse))
        #expect(model.error != nil)
    }
}
