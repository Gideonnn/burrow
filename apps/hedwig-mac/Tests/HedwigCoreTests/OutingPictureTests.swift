import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HedwigCore

@MainActor
@Suite(.serialized) struct OutingPictureTests {
    private static func outingJSON(image: String? = nil, updatedAt: String = "2026-10-22T08:00:00.000Z") -> String {
        """
        {"id":"o1","title":"Neon Nineties","kind":"concert","startsAt":"2027-05-13T19:00:00.000Z","endsAt":null,"doorsAt":null,
         "allDay":false,"venue":"Voorbeeldhal","address":null,"organiser":null,"vendor":null,"orderNumber":null,"url":null,
         "notes":"","aliases":[],"inCalendar":false,\(image.map { #""image":\#($0),"# } ?? "")
         "attendees":[{"id":"p1","name":"Gideon"}],"tickets":[],"tasks":[],"mails":[],
         "createdBy":{"id":"p1","name":"Gideon"},"createdAt":"2026-10-22T08:00:00.000Z",
         "updatedBy":{"id":"p1","name":"Gideon"},"updatedAt":"\(updatedAt)"}
        """
    }

    private static func image(_ source: String = "mail", at: String = "2026-10-22T08:00:00.000Z") -> String {
        #"{"source":"\#(source)","contentType":"image/png","updatedAt":"\#(at)"}"#
    }

    private static func decode(_ json: String) throws -> Outing {
        try APIClient.decoder.decode(Outing.self, from: Data(json.utf8))
    }

    private func model(_ server: MockServer) async -> AppModel {
        server.on("GET", "/api/me", json: Fixture.me)
        let client = server.client()
        let model = AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
        await model.start()
        return model
    }

    /// A small picture drawn in memory, in the format asked for.
    private static func picture(_ type: UTType, width: Int = 40, height: Int = 20, alpha: Bool = false) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    // MARK: The contract

    @Test func outingsFromAServerWithoutPicturesStillDecode() throws {
        #expect(try Self.decode(Self.outingJSON()).image == nil)
        #expect(try Self.decode(Self.outingJSON(image: "null")).image == nil)
        let picture = try #require(try Self.decode(Self.outingJSON(image: Self.image("website"))).image)
        #expect(picture.source == .website)
        #expect(try Self.decode(Self.outingJSON(image: Self.image("camera"))).image != nil)
    }

    @Test func eachWayOfSettingAPictureSendsWhatTheServerExpects() throws {
        let encode = { (r: SetOutingImageRequest) in String(decoding: try JSONEncoder().encode(r), as: UTF8.self) }
        #expect(try encode(.option("abc")) == #"{"optionId":"abc"}"#)
        #expect(try encode(.upload("u1")) == #"{"uploadId":"u1"}"#)
        #expect(try encode(.link(URL(string: "https://zaal.example.nl/agenda")!)) == #"{"url":"https:\/\/zaal.example.nl\/agenda"}"#)
    }

    // MARK: Without a picture

    @Test func theColoursComeFromTheTitleAsInTheDesign() {
        // Values from the design's own hash in docs/design/hedwig-event-images.html.
        #expect(TitleColours.hash("Foute Vrijdag XL") == 370_391_153)
        #expect(TitleColours.hash("Café Ünïcode 🎉") == 797_751_579)
        let colours = TitleColours(title: "Foute Vrijdag XL")
        #expect(colours.start == HSL(hue: 113, saturation: 0.40, lightness: 0.30))
        #expect(colours.end == HSL(hue: 153, saturation: 0.46, lightness: 0.20))
        #expect(colours.glow.hue == 133)
        #expect(TitleColours(title: "Foute Vrijdag XL") == colours)
        #expect(TitleColours(title: "Feest 40 jaar Mila").start.hue == 205)
    }

    @Test func coloursConvertToRGB() {
        let red = HSL(hue: 0, saturation: 1, lightness: 0.5).rgb
        #expect(red.red == 1 && red.green == 0 && red.blue == 0)
        let green = HSL(hue: 120, saturation: 1, lightness: 0.25).rgb
        #expect(green.red == 0 && green.green == 0.5 && green.blue == 0)
        let grey = HSL(hue: 300, saturation: 0, lightness: 0.3).rgb
        #expect(abs(grey.red - 0.3) < 1e-9 && abs(grey.blue - 0.3) < 1e-9)
    }

    // MARK: Showing it

    @Test func onlyLargeWidePicturesFillTheBand() {
        #expect(PictureFit(width: 1200, height: 630) == .fill)
        #expect(PictureFit(width: 1000, height: 750) == .fill)
        #expect(PictureFit(width: 400, height: 400) == .framed)
        #expect(PictureFit(width: 480, height: 160) == .framed)
        #expect(PictureFit(width: 1600, height: 1600) == .framed)
    }

    // MARK: Paste and drop

    @Test func aCopiedFileWinsOverItsIcon() {
        let icon = Self.picture(.tiff)
        let poster = URL(fileURLWithPath: "/tmp/poster.jpg")
        #expect(PastedPicture(PastedContents(fileURLs: [poster], images: [icon])) == .file(poster))
        #expect(PastedPicture(PastedContents(fileURLs: [URL(fileURLWithPath: "/tmp/kaarten.pdf")], images: [icon])) == nil)
    }

    @Test func aPictureCopiedInSafariIsUploadedNotFetched() {
        let tiff = Self.picture(.tiff)
        let contents = PastedContents(images: [tiff], urls: [URL(string: "https://cdn.example.com/poster.webp")!])
        #expect(PastedPicture(contents) == .image(tiff))
    }

    @Test func aLinkGoesToTheServer() {
        let page = URL(string: "https://zaal.example.nl/agenda/neon-nineties")!
        #expect(PastedPicture(PastedContents(urls: [page], strings: [page.absoluteString])) == .link(page))
        #expect(PastedPicture(PastedContents(strings: ["  https://zaal.example.nl/agenda\n"])) == .link(URL(string: "https://zaal.example.nl/agenda")!))
        #expect(PastedPicture(PastedContents(strings: ["Kijk op https://zaal.example.nl"])) == nil)
        #expect(PastedPicture(PastedContents(urls: [URL(string: "ftp://zaal.example.nl/poster.png")!])) == nil)
        #expect(PastedPicture(PastedContents(urls: [URL(string: "mailto:info@example.nl")!])) == nil)
        #expect(PastedPicture(PastedContents()) == nil)
    }

    @Test func droppedItemsAreReadLikeThePasteboard() async {
        let png = Self.picture(.png)
        let page = URL(string: "https://zaal.example.nl/agenda")!
        let file = URL(fileURLWithPath: "/tmp/poster.png")
        let image = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        let link = NSItemProvider(object: page as NSURL)
        let dropped = NSItemProvider(object: file as NSURL)
        let text = NSItemProvider(object: "Neon Nineties" as NSString)

        let contents = await PastedContents.load([image, link, dropped, text])
        #expect(contents.images == [png])
        #expect(contents.urls == [page])
        #expect(contents.fileURLs == [file])
        #expect(contents.strings == ["Neon Nineties"])
        #expect(PastedPicture(contents) == .file(file))
    }

    // MARK: Uploading

    @Test func picturesTheServerShowsAreSentAsTheyAre() throws {
        let png = Self.picture(.png)
        let prepared = try #require(PictureUpload.prepare(png))
        #expect(prepared.data == png)
        #expect(prepared.fileExtension == "png")
        #expect(PictureUpload.prepare(Self.picture(.jpeg))?.fileExtension == "jpg")
        #expect(PictureUpload.prepare(Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)) == nil)
        #expect(PictureUpload.prepare(Data("geen afbeelding".utf8)) == nil)
    }

    @Test func otherFormatsBecomeJPEGOrPNG() throws {
        let photo = try #require(PictureUpload.prepare(Self.picture(.tiff)))
        #expect(photo.fileExtension == "jpg")
        #expect(PictureUpload.served(photo.data) == "jpg")
        let cutout = try #require(PictureUpload.prepare(Self.picture(.tiff, alpha: true)))
        #expect(cutout.fileExtension == "png")
        #expect(OutingPicture(data: cutout.data)?.width == 40)
    }

    @Test func aLinkIsSetOnTheServer() async throws {
        let server = MockServer()
        server.on("PUT", "/api/outings/o1/image", json: Self.outingJSON(image: Self.image("website")))
        let model = await model(server)
        let page = URL(string: "https://zaal.example.nl/agenda")!

        #expect(await model.setPicture(PastedContents(urls: [page]), for: "o1"))
        #expect(server.requests("PUT", "/api/outings/o1/image") == [#"{"url":"https:\/\/zaal.example.nl\/agenda"}"#])
        #expect(model.outings.first?.image?.source == .website)
        #expect(model.pictureBusy.isEmpty)
    }

    @Test func pastedBytesAreUploadedFirst() async throws {
        let server = MockServer()
        server.on("POST", "/api/uploads") { _ in (200, #"{"id":"u1","size":0,"received":0}"#) }
        server.on("PUT", "/api/uploads/u1") { [server] _ in
            let size = server.requests("POST", "/api/uploads").last
                .flatMap { try? JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) }?["size"] ?? 0
            return (200, #"{"id":"u1","size":\#(size),"received":\#(size)}"#)
        }
        server.on("PUT", "/api/outings/o1/image", json: Self.outingJSON(image: Self.image("upload")))
        let model = await model(server)

        #expect(await model.setPicture(PastedContents(images: [Self.picture(.tiff)]), for: "o1"))
        #expect(server.requests("POST", "/api/uploads").first?.contains(#""size":0"#) == false)
        #expect(server.requests("PUT", "/api/outings/o1/image") == [#"{"uploadId":"u1"}"#])
        #expect(model.outings.first?.image?.source == .upload)
    }

    @Test func whatIsNoPictureSaysSoInDutch() async throws {
        let server = MockServer()
        server.on("PUT", "/api/outings/o1/image", status: 400, json: #"{"error":"no picture found on that page"}"#)
        let model = await model(server)

        #expect(!(await model.setPicture(PastedContents(strings: ["https://zaal.example.nl"]), for: "o1")))
        #expect(model.error == "Hedwig kan daar geen afbeelding van maken. Probeer een andere afbeelding of link.")

        #expect(!(await model.setPicture(PastedContents(strings: ["oppas regelen"]), for: "o1")))
        #expect(model.error == "Dat is geen afbeelding. Kopieer een afbeelding of een link naar een website.")
        #expect(server.requests("PUT", "/api/outings/o1/image").count == 1)
    }

    @Test func geenAfbeeldingRemovesIt() async throws {
        let server = MockServer()
        server.on("DELETE", "/api/outings/o1/image", json: Self.outingJSON())
        let model = await model(server)
        await model.removePicture(from: "o1")
        #expect(server.requests("DELETE", "/api/outings/o1/image").count == 1)
        #expect(model.outings.first?.image == nil)
    }

    // MARK: The cache

    @Test func eachVersionOfAPictureIsFetchedOnce() async throws {
        let server = MockServer()
        server.onData("GET", "/api/outings/o1/image", Self.picture(.png, width: 1200, height: 630))
        let model = await model(server)
        let first = try Self.decode(Self.outingJSON(image: Self.image(at: "2026-10-22T08:00:00.000Z")))

        #expect(model.cachedPicture(for: first) == nil)
        async let a = model.picture(for: first)
        async let b = model.picture(for: first)
        let (one, two) = await (a, b)
        #expect(one?.fit == .fill && two?.width == 1200)
        #expect(model.cachedPicture(for: first) != nil)
        #expect(server.queries("GET", "/api/outings/o1/image").count == 1)

        let changed = try Self.decode(Self.outingJSON(image: Self.image("upload", at: "2026-10-22T09:00:00.000Z")))
        #expect(model.cachedPicture(for: changed) == nil)
        _ = await model.picture(for: changed)
        #expect(server.queries("GET", "/api/outings/o1/image") == ["v=1792656000000", "v=1792659600000"])

        let without = try Self.decode(Self.outingJSON())
        #expect(await model.picture(for: without) == nil)
        #expect(server.queries("GET", "/api/outings/o1/image").count == 2)
    }

    @Test func theCacheKeepsALimitedNumberOfOutings() async {
        let cache = OutingPictureCache(limit: 2)
        let picture = OutingPicture(data: Self.picture(.png))
        let at = Date(timeIntervalSince1970: 0)
        for id in ["a", "b", "c"] { _ = await cache.picture(id, version: at) { picture } }
        #expect(cache.cached("a", version: at) == nil)
        #expect(cache.cached("c", version: at) != nil)
    }
}
