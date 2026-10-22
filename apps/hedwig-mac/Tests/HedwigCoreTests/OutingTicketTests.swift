import Foundation
import Testing
@testable import HedwigCore

@Suite struct OutingTicketTests {
    private static func outing(links: String?) throws -> Outing {
        let text = """
        {"id":"o1","title":"Neon Nineties","kind":null,"startsAt":"2027-05-13T19:00:00.000Z","endsAt":null,"doorsAt":null,
         "allDay":false,"venue":null,"address":null,"organiser":null,"vendor":null,"orderNumber":null,"url":null,
         "notes":"","aliases":[],"inCalendar":false,"attendees":[],"tickets":[],"tasks":[],"mails":[],\(links.map { #""ticketLinks":\#($0),"# } ?? "")
         "createdBy":{"id":"p1","name":"Gideon"},"createdAt":"2026-10-22T08:00:00.000Z",
         "updatedBy":{"id":"p1","name":"Gideon"},"updatedAt":"2026-10-22T08:00:00.000Z"}
        """
        return try APIClient.decoder.decode(Outing.self, from: Data(text.utf8))
    }

    @Test func anOlderServerWithoutLinksStillDecodes() throws {
        let outing = try Self.outing(links: nil)
        #expect(outing.shopLinks.isEmpty)
        #expect(outing.shopSentence == nil)
    }

    @Test func oneButtonPerShopTheFirstLinkWins() throws {
        let outing = try Self.outing(links: """
        [{"url":"https://shop.example.com/a","label":"Kaartjes bij Paylogic","messageId":"m1"},
         {"url":"https://shop.example.com/b","label":"Kaartjes bij Paylogic","messageId":"m1"},
         {"url":"javascript:alert(1)","label":"Kaartjes bij Weeztix","messageId":"m2"},
         {"url":"https://tickets.example.nl/c","label":"Kaartjes bij Weeztix","messageId":"m2"}]
        """)
        #expect(outing.shopLinks.map(\.url) == ["https://shop.example.com/a", "https://tickets.example.nl/c"])
        #expect(outing.shopSentence == "Je kaartjes staan bij Paylogic en Weeztix")
        #expect(OutingTicketLink(url: "https://x.example.com", label: "De winkel", messageId: "m").shop == "De winkel")
    }

    @Test func passKitFormatsMapToCoreImageGenerators() {
        #expect(PassBarcode.Format(passKit: "PKBarcodeFormatQR")?.filterName == "CIQRCodeGenerator")
        #expect(PassBarcode.Format(passKit: "PKBarcodeFormatPDF417")?.filterName == "CIPDF417BarcodeGenerator")
        #expect(PassBarcode.Format(passKit: "PKBarcodeFormatAztec")?.filterName == "CIAztecCodeGenerator")
        #expect(PassBarcode.Format(passKit: "PKBarcodeFormatCode128")?.filterName == "CICode128BarcodeGenerator")
        #expect(PassBarcode.Format(passKit: "PKBarcodeFormatNope") == nil)
    }

    @Test func barcodesDrawInTheirShape() throws {
        let qr = try #require(PassBarcode(format: .qr, message: "NN-48291-1", encoding: "iso-8859-1").image())
        #expect(qr.width == qr.height && qr.width > 20)
        let strip = try #require(PassBarcode(format: .pdf417, message: "NN-48291-1", encoding: "utf-8").image())
        #expect(strip.width > strip.height)
        #expect(PassBarcode(format: .aztec, message: "NN-48291-1", encoding: "iso-8859-1").image() != nil)
    }

    @Test func passColoursReadCssAndHex() {
        #expect(PassColour("rgb(255, 0, 51)") == PassColour("#ff0033"))
        #expect(PassColour("rgb(300, 0, 0)") == nil)
        #expect(PassColour(nil) == nil)
    }

    private static let passJSON = """
    {"formatVersion":1,"description":"Toegangskaart","organizationName":"Kaartloket","foregroundColor":"rgb(255,255,255)",
     "backgroundColor":"rgb(20, 30, 80)",
     "barcode":{"format":"PKBarcodeFormatPDF417","message":"OLD","messageEncoding":"iso-8859-1"},
     "barcodes":[{"format":"PKBarcodeFormatQR","message":"NN-48291-1","messageEncoding":"iso-8859-1","altText":"48291-1"}],
     "eventTicket":{"primaryFields":[{"key":"event","label":"Evenement","value":"Neon Nineties"}],
       "secondaryFields":[{"key":"row","label":"Rij","value":5},{"key":"seat","label":"Stoel","value":"12"}],
       "auxiliaryFields":[{"key":"gate","label":"Ingang","value":""}]}}
    """

    @Test func readsAPassFromItsZip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(Self.passJSON.utf8).write(to: dir.appendingPathComponent("pass.json"))
        try Data(repeating: 7, count: 300).write(to: dir.appendingPathComponent("icon.png"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", "-9", "ticket.pkpass", "icon.png", "pass.json"]
        try zip.run()
        zip.waitUntilExit()

        let pass = try #require(TicketPass(pkpass: try Data(contentsOf: dir.appendingPathComponent("ticket.pkpass"))))
        #expect(pass.title == "Neon Nineties")
        #expect(pass.organisation == "Kaartloket")
        #expect(pass.fields == [.init(label: "Rij", value: "5"), .init(label: "Stoel", value: "12")])
        #expect(pass.barcode == PassBarcode(format: .qr, message: "NN-48291-1", encoding: "iso-8859-1", altText: "48291-1"))
        #expect(pass.background == PassColour("rgb(20,30,80)"))
    }

    @Test func anOldPassWithOnlyBarcodeStillHasItsCode() throws {
        let json = #"{"description":"Kaart","barcode":{"format":"PKBarcodeFormatAztec","message":"A1"}}"#
        let pass = try #require(TicketPass(json: Data(json.utf8)))
        #expect(pass.barcode?.format == .aztec)
        #expect(pass.title == "Kaart")
        #expect(TicketPass(pkpass: Data("not a zip".utf8)) == nil)
    }
}
