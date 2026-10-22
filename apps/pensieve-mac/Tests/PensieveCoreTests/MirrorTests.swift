import Foundation
import PensieveMedia
import Testing
@testable import PensieveCore

@MainActor
@Suite(.serialized) struct MirrorTests {
    let probe = FakeProbe(source: VideoSource(seconds: 61, width: 1920, height: 1080, bytes: 0))

    func server(_ recordings: [String], details: [String: String]) -> MockServer {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/people", json: "[]")
        server.on("GET", "/api/pensieve/labels", json: "[]")
        server.on("GET", "/api/pensieve/recordings", json: "[\(recordings.joined(separator: ","))]")
        for (id, json) in details {
            server.on("GET", "/api/pensieve/recordings/\(id)", json: json)
            server.on("GET", "/api/pensieve/recordings/\(id)/audio", json: "AAC!")
        }
        return server
    }

    func summaries(_ json: [String]) throws -> [RecordingSummary] {
        try APIClient.decoder.decode([RecordingSummary].self, from: Data("[\(json.joined(separator: ","))]".utf8))
    }

    @Test func movesAFolderOfTheFirstCopyToTheNewNamesWithoutLosingOrDoublingIt() async throws {
        let root = temporaryDirectory()
        let old = root.appendingPathComponent("2026-10-20_offerte-poorten")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try "# Offerte poorten\n\noud".write(to: old.appendingPathComponent("notulen.md"), atomically: true, encoding: .utf8)
        try "A: Vrijdag.".write(to: old.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try "AAC!".write(to: old.appendingPathComponent("audio.m4a"), atomically: true, encoding: .utf8)
        try #"{"id":"r1","updatedAt":"2026-10-20T10:00:00Z","audioBytes":4}"#
            .write(to: old.appendingPathComponent(".pensieve.json"), atomically: true, encoding: .utf8)

        let recording = Fixture.recording("r1", labels: ["Werk", "Studio Vos"])
        let server = server([recording], details: ["r1": Fixture.detail("r1", labels: ["Werk", "Studio Vos"])])
        let report = try await Mirror(root: root, probe: probe).sync(try summaries([recording]), api: server.client())

        #expect(report.written == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["2026-10-20_offerte-poorten"])
        let files = try FileManager.default.contentsOfDirectory(atPath: old.path).sorted()
        #expect(files == [".pensieve.json", "audio.m4a", "samenvatting.md", "transcript.md"])
        let summary = try String(contentsOf: old.appendingPathComponent("samenvatting.md"), encoding: .utf8)
        #expect(summary.hasPrefix("# Offerte poorten\n\n20 oktober 2026 · 1 min · Werk, Studio Vos\n\n## Samenvatting"))
        #expect(server.requests("GET", "/api/pensieve/recordings/r1/audio").isEmpty)
        let tags = try old.resourceValues(forKeys: [.tagNamesKey]).tagNames
        #expect(tags == ["Werk", "Studio Vos"])

        // Nothing changed since: nothing is fetched again.
        try await Mirror(root: root, probe: probe).sync(try summaries([recording]), api: server.client())
        #expect(server.requests("GET", "/api/pensieve/recordings/r1").count == 1)
    }

    @Test func writesTheTranscriptWithTimesTheSubtitlesAndTheMarks() async throws {
        let root = temporaryDirectory()
        let extra = ###","transcript":"Welkom.","segments":[{"start":0,"end":1.5,"speaker":"A","text":"Welkom."}],"marks":[{"at":250,"note":"Eerste oven, 2009"}],"notes":null,"notesMarkdown":"## Kern\n\nKort."}"###
        let recording = Fixture.recording("v1", title: "Interview Femke de Wit", kind: "video", hasSegments: true)
        let server = server([recording], details: ["v1": Fixture.detail("v1", title: "Interview Femke de Wit", kind: "video", extra: extra)])
        server.on("GET", "/api/pensieve/recordings/v1/subtitles", json: "1\n00:00:00,000 --> 00:00:01,500\nWelkom.\n")
        try await Mirror(root: root, probe: probe).sync(try summaries([recording]), api: server.client())

        let folder = root.appendingPathComponent("2026-10-20_interview-femke-de-wit")
        #expect(try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8).hasSuffix("**00:00** A: Welkom.\n"))
        #expect(try String(contentsOf: folder.appendingPathComponent("ondertitels.srt"), encoding: .utf8).contains("Welkom."))
        #expect(try String(contentsOf: folder.appendingPathComponent("samenvatting.md"), encoding: .utf8).hasSuffix("## Gemarkeerd\n\n- 04:10 Eerste oven, 2009\n"))
    }

    func shelved(_ shelf: Shelf, recordingId: String) throws -> ShelfItem {
        let original = try shelf.newOriginal()
        try Data(repeating: 1, count: 64).write(to: original)
        var item = ShelfItem(id: "u1", kind: .video, title: "Interview Femke de Wit", startedAt: Date(), original: original.path)
        let video = shelf.dir.appendingPathComponent("u1.mp4")
        try Data(repeating: 2, count: 16).write(to: video)
        item.video = video.lastPathComponent
        item.recordingId = recordingId
        try shelf.save(item)
        return item
    }

    @Test func placesTheVideoAndDeletesTheOriginalOnlyOnceICloudHasIt() async throws {
        let root = temporaryDirectory()
        let shelf = Shelf(dir: temporaryDirectory())
        let item = try shelved(shelf, recordingId: "v1")
        let recording = Fixture.recording("v1", title: "Interview Femke de Wit", kind: "video")
        let server = server([recording], details: ["v1": Fixture.detail("v1", title: "Interview Femke de Wit", kind: "video")])
        let folder = root.appendingPathComponent("2026-10-20_interview-femke-de-wit")

        let waiting = try await Mirror(root: root, probe: probe, isUploaded: { _ in false })
            .sync(try summaries([recording]), api: server.client(), shelf: shelf)
        #expect(waiting.waiting == 1)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("interview-femke-de-wit.mp4").path))
        #expect(FileManager.default.fileExists(atPath: item.original))

        let settled = try await Mirror(root: root, probe: probe, isUploaded: { _ in true })
            .sync(try summaries([recording]), api: server.client(), shelf: shelf)
        #expect(settled.settled == 1)
        #expect(!FileManager.default.fileExists(atPath: item.original))
        #expect(shelf.all().isEmpty)
        #expect(try Data(contentsOf: folder.appendingPathComponent("interview-femke-de-wit.mp4")).count == 16)
    }

    @Test func keepsTheOriginalWhenTheCopyDoesNotPlay() async throws {
        let root = temporaryDirectory()
        let shelf = Shelf(dir: temporaryDirectory())
        let item = try shelved(shelf, recordingId: "v1")
        let recording = Fixture.recording("v1", title: "Interview Femke de Wit", kind: "video")
        let server = server([recording], details: ["v1": Fixture.detail("v1", title: "Interview Femke de Wit", kind: "video")])
        var broken = probe
        broken.plays = false
        let report = try await Mirror(root: root, probe: broken, isUploaded: { _ in true })
            .sync(try summaries([recording]), api: server.client(), shelf: shelf)
        #expect(report.settled == 0)
        #expect(FileManager.default.fileExists(atPath: item.original))
        #expect(shelf.all().count == 1)
    }

    @Test func renamesTheVideoWithItsRecording() async throws {
        let root = temporaryDirectory()
        let folder = root.appendingPathComponent("2026-10-20_video")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 16).write(to: folder.appendingPathComponent("video.mp4"))
        try #"{"id":"v1","updatedAt":"2026-10-20T09:00:00Z","audioBytes":4,"layout":2}"#
            .write(to: folder.appendingPathComponent(".pensieve.json"), atomically: true, encoding: .utf8)
        let recording = Fixture.recording("v1", title: "Interview Femke de Wit", kind: "video")
        let server = server([recording], details: ["v1": Fixture.detail("v1", title: "Interview Femke de Wit", kind: "video")])
        try await Mirror(root: root, probe: probe).sync(try summaries([recording]), api: server.client())
        let moved = root.appendingPathComponent("2026-10-20_interview-femke-de-wit")
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("interview-femke-de-wit.mp4").path))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func keepsDictationsTogetherWithTheirTextAndSound() async throws {
        let root = temporaryDirectory()
        let extra = ###","transcript":"Hoi Ruben, de kozijnen.","segments":null,"marks":[],"notes":null,"notesMarkdown":null}"###
        let recording = Fixture.recording("d1", title: "Mail aan de aannemer", kind: "dictation")
        let server = server([recording], details: ["d1": Fixture.detail("d1", title: "Mail aan de aannemer", kind: "dictation", extra: extra)])
        try await Mirror(root: root, probe: probe).sync(try summaries([recording]), api: server.client())

        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["dictaten"])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("dictaten").path).sorted()
        #expect(files.count == 3)
        #expect(files.contains { $0.hasSuffix("_mail-aan-de-aannemer.md") })
        #expect(files.contains { $0.hasSuffix("_mail-aan-de-aannemer.m4a") })

        let renamed = Fixture.recording("d1", title: "Kozijnen", updatedAt: "2026-10-20T12:00:00.000Z", kind: "dictation")
        try await Mirror(root: root, probe: probe).sync(try summaries([renamed]), api: server.client())
        let after = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("dictaten").path)
        #expect(after.count == 3)
        #expect(after.contains { $0.hasSuffix("_kozijnen.m4a") })
        #expect(server.requests("GET", "/api/pensieve/recordings/d1/audio").count == 1)
    }
}

@MainActor
@Suite(.serialized) struct VideoAndDictationTests {
    func model(_ server: MockServer, outbox: Outbox, shelf: Shelf, mirror: Mirror, encoder: VideoEncoder, probe: MediaProbing) -> PensieveModel {
        let client = server.client()
        return PensieveModel(
            store: ConnectionStore(service: "app.burrow.pensieve.tests"), makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"),
            outbox: outbox, mirror: mirror, shelf: shelf, encoder: encoder, probe: probe,
            extractAudio: { _, audio in try Data("M4A!".utf8).write(to: audio) })
    }

    func server() -> MockServer {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/people", json: "[]")
        server.on("GET", "/api/pensieve/labels", json: "[]")
        server.on("POST", "/api/uploads", status: 201, json: #"{"id":"u1","size":4,"received":0}"#)
        server.on("PUT", "/api/uploads/u1", json: #"{"id":"u1","size":4,"received":4}"#)
        server.on("GET", "/api/uploads/u1", json: #"{"id":"u1","size":4,"received":4}"#)
        return server
    }

    @Test func aVideoSendsOnlyItsSoundAndEndsUpSmallInICloud() async throws {
        let server = server()
        let video = Fixture.recording("v1", title: "Interview Femke de Wit", status: "stored", kind: "video", labels: ["Interviews"])
        server.on("POST", "/api/pensieve/recordings", status: 201, json: video)
        server.on("GET", "/api/pensieve/recordings", json: "[\(video)]")
        server.on("GET", "/api/pensieve/recordings/v1", json: Fixture.detail("v1", title: "Interview Femke de Wit", kind: "video", labels: ["Interviews"]))
        server.on("GET", "/api/pensieve/recordings/v1/audio", json: "AAC!")
        let shelf = Shelf(dir: temporaryDirectory())
        let root = temporaryDirectory()
        let probe = FakeProbe(source: VideoSource(seconds: 61, width: 1920, height: 1080, bytes: 0))
        let encoder = FakeEncoder(seconds: 61)
        let model = model(
            server, outbox: Outbox(dir: temporaryDirectory()), shelf: shelf,
            mirror: Mirror(root: root, probe: probe, isUploaded: { _ in true }), encoder: encoder, probe: probe)
        await model.start()

        let original = try shelf.newOriginal()
        try Data(repeating: 9, count: 4096).write(to: original)
        await model.finishedVideo(
            original: original, kind: .video, title: "Interview Femke de Wit", startedAt: Date(),
            marks: [Mark(at: 250, note: "Eerste oven")], labels: ["Interviews"])

        #expect(server.requests("PUT", "/api/uploads/u1").first == "M4A!")
        let created = try #require(server.requests("POST", "/api/pensieve/recordings").first)
        #expect(created.contains(#""kind":"video""#))
        #expect(created.contains(#""labels":["Interviews"]"#))
        #expect(created.contains(#""note":"Eerste oven""#))
        #expect(encoder.calls.map(\.height) == [1080])
        let folder = root.appendingPathComponent("2026-10-20_interview-femke-de-wit")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("interview-femke-de-wit.mp4").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(shelf.all().isEmpty)
    }

    @Test func aDictationComesBackAsText() async throws {
        let server = server()
        let dictation = Fixture.recording("d1", title: "Dictaat", status: "transcribing", kind: "dictation")
        server.on("POST", "/api/pensieve/recordings", status: 201, json: dictation)
        server.on("GET", "/api/pensieve/recordings", json: "[]")
        let polls = Counter()
        server.on("GET", "/api/pensieve/recordings/d1") { _ in
            let extra = polls.next() < 2
                ? ###","transcript":null,"segments":null,"marks":[],"notes":null,"notesMarkdown":null}"###
                : ###","transcript":"Hoi Ruben.","segments":null,"marks":[],"notes":null,"notesMarkdown":null}"###
            return (200, Fixture.detail("d1", title: "Dictaat", kind: "dictation", extra: extra))
        }
        let outbox = Outbox(dir: temporaryDirectory())
        let model = model(
            server, outbox: outbox, shelf: Shelf(dir: temporaryDirectory()), mirror: Mirror(root: temporaryDirectory()),
            encoder: FakeEncoder(seconds: 1), probe: AVProbe())
        await model.start()
        let audio = try outbox.newAudioFile(extension: "m4a")
        try Data("M4A!".utf8).write(to: audio)

        let detail = try await model.dictate(audio: audio, startedAt: Date())
        #expect(detail.transcript == "Hoi Ruben.")
        #expect(try #require(server.requests("POST", "/api/pensieve/recordings").first).contains(#""kind":"dictation""#))
        #expect(outbox.all().isEmpty)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}

@MainActor
final class FakePasteTarget: PasteTarget {
    var trusted: Bool
    var frontmostApp: String? = "Mail"
    var changeCount = 0
    var board: String? = "wat er al stond"
    var pressed = 0
    var copyWhilePasting: String?

    init(trusted: Bool) { self.trusted = trusted }

    func clipboard() -> String? { board }
    func setClipboard(_ text: String?) {
        board = text
        changeCount += 1
    }

    func pressPaste() -> Bool {
        pressed += 1
        if let copy = copyWhilePasting { setClipboard(copy) }
        return true
    }
}

@MainActor
@Suite struct PasteTests {
    @Test func pastesAtTheCursorAndGivesTheClipboardBack() async {
        let target = FakePasteTarget(trusted: true)
        let outcome = await Paster(target: target, restoreAfter: .zero).paste("Hoi Ruben.")
        #expect(outcome == .pasted(app: "Mail"))
        #expect(target.pressed == 1)
        #expect(target.board == "wat er al stond")
    }

    @Test func leavesWhatSomeoneCopiedMeanwhile() async {
        let target = FakePasteTarget(trusted: true)
        target.copyWhilePasting = "nieuw gekopieerd"
        _ = await Paster(target: target, restoreAfter: .zero).paste("Hoi Ruben.")
        #expect(target.board == "nieuw gekopieerd")
    }

    @Test func withoutAccessibilityTheTextWaitsOnTheClipboard() async {
        let target = FakePasteTarget(trusted: false)
        let outcome = await Paster(target: target, restoreAfter: .zero).paste("Hoi Ruben.")
        #expect(outcome == .onClipboard)
        #expect(target.pressed == 0)
        #expect(target.board == "Hoi Ruben.")
    }
}

@Suite struct DefaultsTests {
    @Test func aNewRecordingTakesTitleAndLabelsFromThePreviousOfItsKind() throws {
        let json = [
            Fixture.recording("a", title: "Interview Joris Bakker", kind: "video", labels: ["Interviews"]),
            Fixture.recording("b", title: "Teams-overleg", kind: "call", labels: ["Werk"]),
            Fixture.recording("c", title: "Hoi Ruben", kind: "dictation", labels: ["Thuis"]),
        ]
        let recordings = try APIClient.decoder.decode([RecordingSummary].self, from: Data("[\(json.joined(separator: ","))]".utf8))
        #expect(RecordingDefaults.suggestion(for: .video, after: recordings) == ("Interview Joris Bakker", ["Interviews"]))
        #expect(RecordingDefaults.suggestion(for: .dictation, after: recordings) == ("Dictaat", ["Thuis"]))
        #expect(RecordingDefaults.suggestion(for: .screen, after: recordings) == ("Scherm", []))
    }

    @Test func marksStayInOrderAndADoublePressIsOneMoment() {
        var list = MarkList()
        list.mark(at: 15.3)
        list.mark(at: 4.1)
        list.mark(at: 15.8, note: "Mooie quote")
        #expect(list.marks == [Mark(at: 4.1), Mark(at: 15.3, note: "Mooie quote")])
        list.setNote("  ", at: 1)
        #expect(list.marks[1].note == nil)
    }
}
