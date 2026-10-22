import CoreGraphics
import Foundation
import Testing
@testable import HedwigCore

@Suite struct TicketCodeTests {
    /// A pdf like a ticket shop's: an A4 page with each code somewhere on it.
    private static func pdf(_ pages: [[(code: CGImage, at: CGRect)]]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for page in pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 760, width: 595, height: 82))
            context.interpolationQuality = .none
            for item in page { context.draw(item.code, in: item.at) }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func qr(_ text: String) -> CGImage {
        PassBarcode(format: .qr, message: text, encoding: "iso-8859-1").image()!
    }

    @Test func findsTheCodeOnAPdfPageAndDrawsItAgain() throws {
        let data = Self.pdf([[(Self.qr("NN-48291-1"), CGRect(x: 60, y: 300, width: 180, height: 180))]])
        let codes = TicketCodes.find(pdf: data)
        let code = try #require(codes.first)
        #expect(codes.count == 1)
        #expect(code.kind == .qr && code.payload == "NN-48291-1")
        #expect(code.crisp && code.image.width < 100)
        #expect(TicketCodes.find(in: code.image).first?.payload == "NN-48291-1")
    }

    @Test func twoTicketsInOnePdfAreTwoCodesTopFirst() {
        let data = Self.pdf([
            [(Self.qr("KAART-2"), CGRect(x: 300, y: 80, width: 150, height: 150)),
             (Self.qr("KAART-1"), CGRect(x: 60, y: 500, width: 150, height: 150))],
            [(Self.qr("KAART-1"), CGRect(x: 60, y: 500, width: 150, height: 150))],
        ])
        #expect(TicketCodes.find(pdf: data).map(\.payload) == ["KAART-1", "KAART-2"])
    }

    @Test func aPdfWithoutACodeHasNone() {
        #expect(TicketCodes.find(pdf: Self.pdf([[]])).isEmpty)
        #expect(TicketCodes.find(pdf: Data("geen pdf".utf8)).isEmpty)
    }

    @Test func visionSymbologiesMapToKinds() {
        #expect(TicketCodes.kind(.aztec) == .aztec)
        #expect(TicketCodes.kind(.pdf417) == .pdf417)
        #expect(TicketCodes.kind(.ean13) == .other)
    }
}
