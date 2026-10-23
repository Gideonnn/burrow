import Testing
@testable import HedwigCore

struct RecipientLinesTests {
    let sender = Address(name: "Marieke de Vries", email: "marieke@example.nl")
    let bas = Address(name: "Bas", email: "bas@example.nl")
    let owner = Address(email: "owner@example.com")

    @Test func showsToAndCcWithDutchLabels() {
        let lines = RecipientLines.lines(from: sender, to: [owner], cc: [bas], replyTo: [])
        #expect(lines.map(\.label) == ["Aan", "Kopie"])
    }

    @Test func leavesOutAnEmptyCopyLine() {
        let lines = RecipientLines.lines(from: sender, to: [owner], cc: [], replyTo: [])
        #expect(lines.map(\.label) == ["Aan"])
    }

    @Test func showsReplyToOnlyWhenItDiffersFromTheSender() {
        let same = Address(name: "M. de Vries", email: "Marieke@Example.nl")
        #expect(RecipientLines.lines(from: sender, to: [owner], cc: [], replyTo: [same]).map(\.label) == ["Aan"])
        let other = Address(name: "Support", email: "help@example.nl")
        #expect(RecipientLines.lines(from: sender, to: [owner], cc: [], replyTo: [other]).map(\.label) == ["Aan", "Antwoord aan"])
    }

    @Test func usesNamesWhereKnownAndAddressesOtherwise() {
        let line = RecipientLine(kind: .to, addresses: [bas, owner, Address(name: " ", email: "x@example.nl")])
        #expect(line.names(limit: nil).shown == "Bas, owner@example.com, x@example.nl")
    }

    @Test func truncatesLongListsWithACountOfTheRest() {
        let many = (1...6).map { Address(name: "Persoon \($0)", email: "p\($0)@example.nl") }
        let line = RecipientLine(kind: .cc, addresses: many)
        #expect(line.names(limit: 3) == RecipientNames(shown: "Persoon 1, Persoon 2, Persoon 3", more: 3))
        #expect(line.names(limit: nil) == RecipientNames(shown: many.map(\.display).joined(separator: ", "), more: 0))
    }

    @Test func neverHidesASingleNameBehindPlusOne() {
        let four = (1...4).map { Address(email: "p\($0)@example.nl") }
        #expect(RecipientLine(kind: .to, addresses: four).names(limit: 3).more == 0)
    }

    @Test func theTooltipListsEveryAddress() {
        let line = RecipientLine(kind: .to, addresses: [bas, owner])
        #expect(line.tooltip == "Bas <bas@example.nl>\nowner@example.com")
    }
}
