import BurrowKit
import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite(.serialized) struct ListFilterTests {
    private func defaults() -> UserDefaults {
        let name = "app.burrow.hedwig.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func model(_ server: MockServer, defaults: UserDefaults) -> AppModel {
        let client = server.client()
        return AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"),
            defaults: defaults)
    }

    private func server() -> MockServer {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/filtered", json: "[]")
        server.on("GET", "/api/drafts", json: "[]")
        server.on("GET", "/api/mailboxes/counts", json: "[]")
        server.on("GET", "/api/mailboxes/mb1/messages", json: "[\(Fixture.message("m1", subject: "Eerste")),\(Fixture.message("m2", subject: "Tweede"))]")
        server.on("GET", "/api/messages/m1", json: Fixture.message("m1", subject: "Eerste"))
        server.on("GET", "/api/messages/m2", json: Fixture.message("m2", subject: "Tweede"))
        server.on("POST", "/api/messages/m1/actions", json: Fixture.message("m1", subject: "Eerste", unread: false))
        server.on("POST", "/api/messages/m2/actions", json: Fixture.message("m2", subject: "Tweede", unread: false))
        return server
    }

    private func lastListQuery(_ server: MockServer) -> String {
        server.queries("GET", "/api/mailboxes/mb1/messages").last ?? ""
    }

    @Test func theServerFiltersTheWholeFolder() async {
        let server = server()
        let model = model(server, defaults: defaults())
        model.selection = .inbox(mailboxId: "mb1")
        await model.selectionLoad?.value
        #expect(!lastListQuery(server).contains("filter="))

        model.filterCriteria = [.attachments, .unread]
        model.filterOn = true
        await model.selectionLoad?.value
        #expect(lastListQuery(server).contains("filter=unread,attachments"))
        #expect(model.filterDescription == "Gefilterd op: Ongelezen, Met bijlagen")

        model.filterOn = false
        await model.selectionLoad?.value
        #expect(!lastListQuery(server).contains("filter="))
        #expect(model.filterDescription == nil)
    }

    @Test func todayIsSentAsTheStartOfTheLocalDay() async throws {
        let server = server()
        let model = model(server, defaults: defaults())
        model.selection = .inbox(mailboxId: "mb1")
        await model.selectionLoad?.value
        model.filterCriteria = [.today]
        model.filterOn = true
        await model.selectionLoad?.value
        let query = lastListQuery(server)
        #expect(!query.contains("filter="))
        let since = try #require(query.split(separator: "&").first { $0.hasPrefix("since=") }?.dropFirst(6))
        let date = try #require(APIClient.isoFractional.date(from: String(since)))
        #expect(date == Calendar.current.startOfDay(for: .now))
    }

    @Test func theCriteriaPersistButTheFilterStartsOff() {
        let store = defaults()
        let first = model(server(), defaults: store)
        #expect(first.filterCriteria == [.unread])
        first.filterCriteria = [.flagged, .toMe]
        first.filterOn = true

        let second = model(server(), defaults: store)
        #expect(second.filterCriteria == [.flagged, .toMe])
        #expect(!second.filterOn)
    }

    @Test func theLastCriterionStays() {
        let model = model(server(), defaults: defaults())
        model.toggle(.unread)
        #expect(model.filterCriteria == [.unread])
        model.toggle(.flagged)
        model.toggle(.unread)
        #expect(model.filterCriteria == [.flagged])
    }

    // Like Mail: opening an unread mail under "Ongelezen" reads it, but it stays in the
    // list until you move on, also when a live update reloads the list.
    @Test func readMailStaysUntilYouMoveOn() async {
        let server = server()
        let model = model(server, defaults: defaults())
        model.filterOn = true
        await model.start()
        await model.selectionLoad?.value
        await model.messageLoad?.value
        #expect(model.selectedMessageId == "m1")
        #expect(model.messages.first?.unread == false)

        server.on("GET", "/api/mailboxes/mb1/messages", json: "[\(Fixture.message("m2", subject: "Tweede"))]")
        await model.handle(ServerEvent(type: "message.changed", fields: ["mailboxId": "mb1"]))
        #expect(model.messages.map(\.id) == ["m1", "m2"])

        model.selectedMessageId = "m2"
        await model.messageLoad?.value
        #expect(model.messages.map(\.id) == ["m2"])
    }
}
