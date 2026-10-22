import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite struct OutingPlaceTests {
    private static func outing(venue: String?, address: String?, kind: String? = nil) throws -> Outing {
        func json(_ text: String?) -> String { text.map { "\"\($0)\"" } ?? "null" }
        let text = """
        {"id":"o1","title":"Neon Nineties","kind":\(json(kind)),"startsAt":"2027-05-13T19:00:00.000Z","endsAt":null,"doorsAt":null,
         "allDay":false,"venue":\(json(venue)),"address":\(json(address)),"organiser":null,"vendor":null,"orderNumber":null,"url":null,
         "notes":"","aliases":[],"inCalendar":false,"attendees":[],"tickets":[],"tasks":[],"mails":[],
         "createdBy":{"id":"p1","name":"Gideon"},"createdAt":"2026-10-22T08:00:00.000Z",
         "updatedBy":{"id":"p1","name":"Gideon"},"updatedAt":"2026-10-22T08:00:00.000Z"}
        """
        return try APIClient.decoder.decode(Outing.self, from: Data(text.utf8))
    }

    private static let hall = OutingPlace(latitude: 51.7, longitude: 5.3, name: "Voorbeeldhal", city: "Voorbeeldstad")

    @Test func asksForVenueAndAddressThenTheAddress() {
        #expect(PlaceQuery.queries(venue: "Voorbeeldhal", address: "Voorbeeldstad") == ["Voorbeeldhal, Voorbeeldstad", "Voorbeeldstad"])
        #expect(PlaceQuery.queries(venue: "Voorbeeldhal", address: "Voorbeeldhal 1, Voorbeeldstad") == ["Voorbeeldhal 1, Voorbeeldstad"])
        #expect(PlaceQuery.queries(venue: "  Voorbeeldhal ", address: nil) == ["Voorbeeldhal"])
        #expect(PlaceQuery.queries(venue: nil, address: "Dorpsstraat 1,  Voorbeelddorp") == ["Dorpsstraat 1, Voorbeelddorp"])
        #expect(PlaceQuery.queries(venue: " ", address: nil).isEmpty)
    }

    @Test func theSamePlaceTypedDifferentlyIsOneEntry() {
        #expect(PlaceQuery.key(venue: "Voorbeeldhal", address: "Voorbeeldstad") == PlaceQuery.key(venue: " voorbeeldhal", address: "VOORBEELDSTAD "))
        #expect(PlaceQuery.key(venue: "Voorbeeldhal", address: nil) != PlaceQuery.key(venue: nil, address: "Voorbeeldhal"))
        #expect(PlaceQuery.key(venue: nil, address: "") == nil)
    }

    @Test func labelsTheMapWithVenueAndCityOnce() throws {
        let both = try Self.outing(venue: "Voorbeeldhal", address: "Hallenweg 1, Voorbeeldstad").placeLabel(Self.hall)
        #expect(both.title == "Voorbeeldhal" && both.subtitle == "Voorbeeldstad")
        let addressOnly = try Self.outing(venue: nil, address: "Hallenweg 1").placeLabel(OutingPlace(latitude: 0, longitude: 0, name: "Hallenweg 1"))
        #expect(addressOnly.title == "Hallenweg 1" && addressOnly.subtitle == nil)
        let cityAsVenue = try Self.outing(venue: "Voorbeeldstad", address: nil).placeLabel(Self.hall)
        #expect(cityAsVenue.title == "Voorbeeldstad" && cityAsVenue.subtitle == nil)
    }

    @Test func travelTimeReadsAsDutch() {
        #expect(TravelTime.text(seconds: 7 * 60) == "ca. 7 min met de auto")
        #expect(TravelTime.text(seconds: 23 * 60) == "ca. 25 min met de auto")
        #expect(TravelTime.text(seconds: 58 * 60) == "ca. 1 uur met de auto")
        #expect(TravelTime.text(seconds: 71 * 60) == "ca. 1 uur en 10 min met de auto")
        #expect(TravelTime.text(seconds: 30) == nil)
        #expect(TravelTime.text(seconds: 20 * 3600) == nil)
    }

    @Test func mapsLinksPointAtThePlace() {
        let place = MapsLink.place(Self.hall, query: "Voorbeeldhal, Voorbeeldstad").absoluteString
        #expect(place == "http://maps.apple.com/?q=Voorbeeldhal,%20Voorbeeldstad&ll=51.7,5.3")
        #expect(MapsLink.route(to: "Voorbeeldhal").absoluteString == "http://maps.apple.com/?daddr=Voorbeeldhal")
    }

    @Test func pinShowsTheKind() throws {
        #expect(try Self.outing(venue: nil, address: nil, kind: "90's party").kindSymbol == "party.popper.fill")
        #expect(try Self.outing(venue: nil, address: nil, kind: "Cabaret").kindSymbol == "theatermasks.fill")
        #expect(try Self.outing(venue: nil, address: nil).kindSymbol == "star.fill")
    }

    @Test func looksUpOnceAndRemembersOnDisk() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("places-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var asked: [String] = []
        let book = PlaceBook(file: file) { query in
            asked.append(query)
            return query == "Voorbeeldstad" ? .found(Self.hall) : .notFound
        }
        let outing = try Self.outing(venue: "Voorbeeldhal", address: "Voorbeeldstad")
        #expect(book.cached(outing) == nil)
        #expect(await book.place(for: outing) == Self.hall)
        #expect(await book.place(for: outing) == Self.hall)
        #expect(asked == ["Voorbeeldhal, Voorbeeldstad", "Voorbeeldstad"])

        let reopened = PlaceBook(file: file) { _ in Issue.record("searched again"); return .notFound }
        #expect(reopened.cached(outing) == Self.hall)
    }

    @Test func asksAgainOnlyAfterNoAnswer() async throws {
        var answers: [PlaceSearchResult] = [.failed, .found(Self.hall)]
        var nothing = 0
        let book = PlaceBook(file: nil) { query in
            if query == "Nergens" { nothing += 1; return .notFound }
            return answers.removeFirst()
        }
        let offline = try Self.outing(venue: "Voorbeeldhal", address: nil)
        #expect(await book.place(for: offline) == nil)
        #expect(await book.place(for: offline) == Self.hall)

        let unknown = try Self.outing(venue: "Nergens", address: nil)
        #expect(await book.place(for: unknown) == nil)
        #expect(await book.place(for: unknown) == nil)
        #expect(nothing == 1)
    }
}
