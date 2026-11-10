import Compression
import CoreGraphics
import CoreImage
import Foundation

// What the tickets look like on the page: the shop pages where tickets that
// came as a link live, and a Wallet pass read far enough to draw its code.

public struct OutingTicketLink: Codable, Hashable, Sendable {
    public var url: String
    public var label: String
    public var messageId: String

    public init(url: String, label: String, messageId: String) {
        self.url = url
        self.label = label
        self.messageId = messageId
    }

    /// "Kaartjes bij Weeztix" says "Weeztix"; a label in another shape stays whole.
    public var shop: String {
        let prefix = "Kaartjes bij "
        return label.hasPrefix(prefix) ? String(label.dropFirst(prefix.count)) : label
    }

    public var webURL: URL? {
        guard let url = URL(string: url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

extension Outing {
    /// One button per shop: the first link wins, as Paylogic sends two.
    public var shopLinks: [OutingTicketLink] {
        var seen = Set<String>()
        return (ticketLinks ?? []).filter { $0.webURL != nil && seen.insert($0.label.lowercased()).inserted }
    }

    /// "Je kaartjes staan bij Weeztix", or "bij Weeztix en Paylogic".
    public var shopSentence: String? {
        let shops = shopLinks.map(\.shop)
        guard let last = shops.last else { return nil }
        let names = shops.count == 1 ? last : shops.dropLast().joined(separator: ", ") + " en " + last
        return "Je kaartjes staan bij \(names)"
    }
}

// MARK: Wallet passes

public struct PassColour: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    /// Passes write colours as CSS "rgb(12, 34, 56)"; some shops use "#0c2238".
    public init?(_ text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if text.hasPrefix("#"), text.count == 7, let value = Int(text.dropFirst(), radix: 16) {
            (red, green, blue) = (Double(value >> 16 & 255) / 255, Double(value >> 8 & 255) / 255, Double(value & 255) / 255)
            return
        }
        guard text.hasPrefix("rgb"), let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")") else { return nil }
        let parts = text[text.index(after: open)..<close].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3, parts.prefix(3).allSatisfy({ (0...255).contains($0) }) else { return nil }
        (red, green, blue) = (parts[0] / 255, parts[1] / 255, parts[2] / 255)
    }
}

public struct PassBarcode: Hashable, Sendable {
    public enum Format: String, Sendable {
        case qr, pdf417, aztec, code128

        public init?(passKit name: String) {
            switch name {
            case "PKBarcodeFormatQR": self = .qr
            case "PKBarcodeFormatPDF417": self = .pdf417
            case "PKBarcodeFormatAztec": self = .aztec
            case "PKBarcodeFormatCode128": self = .code128
            default: return nil
            }
        }

        public var filterName: String {
            switch self {
            case .qr: "CIQRCodeGenerator"
            case .pdf417: "CIPDF417BarcodeGenerator"
            case .aztec: "CIAztecCodeGenerator"
            case .code128: "CICode128BarcodeGenerator"
            }
        }

        /// QR and Aztec are square; the others are wide strips.
        public var isSquare: Bool { self == .qr || self == .aztec }
    }

    public var format: Format
    public var message: String
    public var encoding: String
    public var altText: String?

    var messageData: Data? {
        let encoding: String.Encoding = encoding.lowercased().replacingOccurrences(of: "_", with: "-") == "utf-8" ? .utf8 : .isoLatin1
        return message.data(using: encoding) ?? message.data(using: .utf8)
    }

    /// The code at one pixel per module, to be drawn larger without smoothing.
    public func image() -> CGImage? {
        guard let data = messageData, let filter = CIFilter(name: format.filterName) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        if format == .qr { filter.setValue("M", forKey: "inputCorrectionLevel") }
        if format == .code128 { filter.setValue(0, forKey: "inputQuietSpace") }
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent)
    }
}

/// The parts of a pass.json worth showing on a card and at the door.
public struct TicketPass: Hashable, Sendable {
    public struct Field: Hashable, Sendable {
        public var label: String?
        public var value: String
    }

    public var title: String?
    public var organisation: String?
    public var fields: [Field]
    public var barcode: PassBarcode?
    public var background: PassColour?
    public var foreground: PassColour?

    public init?(pkpass: Data) {
        guard let json = ZipReader.file(named: "pass.json", in: pkpass) else { return nil }
        self.init(json: json)
    }

    public init?(json: Data) {
        guard let pass = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        let style = ["eventTicket", "boardingPass", "coupon", "storeCard", "generic"].lazy.compactMap { pass[$0] as? [String: Any] }.first ?? [:]
        func fields(_ key: String) -> [Field] {
            (style[key] as? [[String: Any]] ?? []).compactMap { field in
                guard let value = Self.text(field["value"]), !value.isEmpty else { return nil }
                return Field(label: Self.text(field["label"]), value: value)
            }
        }
        let primary = fields("primaryFields")
        title = primary.first?.value ?? Self.text(pass["logoText"]) ?? Self.text(pass["description"])
        organisation = Self.text(pass["organizationName"])
        self.fields = Array((primary.dropFirst() + fields("secondaryFields") + fields("auxiliaryFields")).prefix(4))
        let codes = (pass["barcodes"] as? [[String: Any]] ?? []) + [pass["barcode"] as? [String: Any]].compactMap { $0 }
        barcode = codes.lazy.compactMap { code -> PassBarcode? in
            guard let format = (code["format"] as? String).flatMap(PassBarcode.Format.init(passKit:)),
                  let message = code["message"] as? String, !message.isEmpty
            else { return nil }
            return PassBarcode(
                format: format, message: message,
                encoding: code["messageEncoding"] as? String ?? "iso-8859-1",
                altText: code["altText"] as? String)
        }.first
        background = PassColour(pass["backgroundColor"] as? String)
        foreground = PassColour(pass["foregroundColor"] as? String)
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let text as String: text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }
}

// MARK: Zip

/// Reads one file from a zip, enough for a .pkpass: stored or deflated
/// entries, no zip64. Foundation has no zip reader of its own.
enum ZipReader {
    static let maxSize = 8 * 1024 * 1024

    static func file(named name: String, in zip: Data) -> Data? {
        let bytes = [UInt8](zip)
        guard let end = endOfDirectory(bytes) else { return nil }
        let count = Int(u16(bytes, end + 10))
        var at = Int(u32(bytes, end + 16))
        for _ in 0..<count {
            guard at + 46 <= bytes.count, u32(bytes, at) == 0x0201_4B50 else { return nil }
            let method = u16(bytes, at + 10)
            let packed = Int(u32(bytes, at + 20)), size = Int(u32(bytes, at + 24))
            let nameLength = Int(u16(bytes, at + 28)), extra = Int(u16(bytes, at + 30)), comment = Int(u16(bytes, at + 32))
            let local = Int(u32(bytes, at + 42))
            guard at + 46 + nameLength <= bytes.count else { return nil }
            let entry = String(decoding: bytes[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            at += 46 + nameLength + extra + comment
            guard entry == name else { continue }
            guard local + 30 <= bytes.count, u32(bytes, local) == 0x0403_4B50, size <= maxSize else { return nil }
            let start = local + 30 + Int(u16(bytes, local + 26)) + Int(u16(bytes, local + 28))
            guard start + packed <= bytes.count else { return nil }
            let body = Array(bytes[start..<(start + packed)])
            switch method {
            case 0: return Data(body)
            case 8: return inflate(body, size: size)
            default: return nil
            }
        }
        return nil
    }

    private static func endOfDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 65535)
        return stride(from: bytes.count - 22, through: lowest, by: -1).first { u32(bytes, $0) == 0x0605_4B50 }
    }

    // COMPRESSION_ZLIB is raw deflate, which is what zip stores.
    private static func inflate(_ body: [UInt8], size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var out = [UInt8](repeating: 0, count: size)
        let written = compression_decode_buffer(&out, size, body, body.count, nil, COMPRESSION_ZLIB)
        return written == size ? Data(out) : nil
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        i + 2 <= b.count ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : 0
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        i + 4 <= b.count ? UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 : 0
    }
}
