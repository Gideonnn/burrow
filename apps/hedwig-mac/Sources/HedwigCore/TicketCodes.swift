import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// A code found on a ticket, ready to show at the door: drawn again from what
/// it says when possible, so it is crisp at any size; otherwise cut out of
/// the page with a margin.
public struct TicketCode: @unchecked Sendable, Hashable {
    public enum Kind: String, Sendable { case qr, aztec, pdf417, dataMatrix, code128, other }

    public let kind: Kind
    public let payload: String?
    public let image: CGImage
    /// Drawn module by module: scale it without smoothing.
    public let crisp: Bool

    public var isSquare: Bool { [.qr, .aztec, .dataMatrix].contains(kind) }

    public init(kind: Kind, payload: String?, image: CGImage, crisp: Bool) {
        self.kind = kind
        self.payload = payload
        self.image = image
        self.crisp = crisp
    }

    public static func == (a: TicketCode, b: TicketCode) -> Bool {
        a.kind == b.kind && a.payload == b.payload && a.image === b.image
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(payload)
    }
}

public enum TicketCodes {
    /// Every code on every page of a pdf, top to bottom, each once.
    public static func find(pdf data: Data) -> [TicketCode] {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return [] }
        var codes: [TicketCode] = []
        for number in 1...max(1, min(document.numberOfPages, 20)) {
            guard let page = document.page(at: number), let image = render(page) else { continue }
            codes += find(in: image)
        }
        return unique(codes)
    }

    /// The codes in a picture: a screenshot or a photo of a ticket.
    public static func find(imageData data: Data) -> [TicketCode] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return [] }
        return find(in: image)
    }

    public static func find(in image: CGImage) -> [TicketCode] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .aztec, .pdf417, .dataMatrix, .code128]
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let found = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        return unique(found.compactMap { code(from: $0, on: image) })
    }

    static func kind(_ symbology: VNBarcodeSymbology) -> TicketCode.Kind {
        switch symbology {
        case .qr: .qr
        case .aztec: .aztec
        case .pdf417: .pdf417
        case .dataMatrix: .dataMatrix
        case .code128: .code128
        default: .other
        }
    }

    private static func code(from observation: VNBarcodeObservation, on page: CGImage) -> TicketCode? {
        let kind = kind(observation.symbology)
        let payload = observation.payloadStringValue
        if let image = redraw(observation, kind: kind, payload: payload) {
            return TicketCode(kind: kind, payload: payload, image: image, crisp: true)
        }
        guard let image = cut(observation.boundingBox, from: page) else { return nil }
        return TicketCode(kind: kind, payload: payload, image: image, crisp: false)
    }

    /// The exact symbol from Vision's descriptor (same bytes, version and
    /// error correction); Code 128 has none, so it is drawn from its text.
    private static func redraw(_ observation: VNBarcodeObservation, kind: TicketCode.Kind, payload: String?) -> CGImage? {
        if let descriptor = observation.barcodeDescriptor, let filter = CIFilter(name: "CIBarcodeGenerator") {
            filter.setValue(descriptor, forKey: "inputBarcodeDescriptor")
            if let image = filter.outputImage.flatMap(cgImage) { return image }
        }
        guard kind == .code128, let payload else { return nil }
        return PassBarcode(format: .code128, message: payload, encoding: "iso-8859-1").image()
    }

    private static func cut(_ box: CGRect, from page: CGImage) -> CGImage? {
        let width = CGFloat(page.width), height = CGFloat(page.height)
        var rect = CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
        rect = rect.insetBy(dx: -rect.width * 0.08 - 8, dy: -rect.height * 0.08 - 8)
        return page.cropping(to: rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral)
    }

    private static func render(_ page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        // About 2000 px across: enough for small codes, not too slow.
        let scale = min(6, 2000 / box.width)
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private static func cgImage(_ image: CIImage) -> CGImage? {
        CIContext().createCGImage(image, from: image.extent)
    }

    private static func unique(_ codes: [TicketCode]) -> [TicketCode] {
        var seen = Set<String>()
        return codes.filter { code in
            guard let payload = code.payload else { return true }
            return seen.insert("\(code.kind.rawValue):\(payload)").inserted
        }
    }
}
