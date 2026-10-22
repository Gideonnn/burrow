import Foundation
import Testing
@testable import PensieveCore

enum Fixture {
    static let me = """
    {"person":{"id":"p1","name":"Eva"},"key":{"id":"k1","name":"Pensieve op Testmac"},
     "rights":["read","organize","tasks"],"admin":true,"settings":{"pensieve.mirror":true}}
    """

    static func recording(_ id: String, title: String = "Offerte poorten", status: String = "done", updatedAt: String = "2026-10-20T10:00:00.000Z", audioBytes: Int = 4) -> String {
        """
        {"id":"\(id)","title":"\(title)","owner":{"id":"p1","name":"Eva"},"mine":true,"sharedWith":[],
         "startedAt":"2026-10-20T09:02:00.000Z","durationSeconds":61,"status":"\(status)","error":null,
         "source":"recorded","audioBytes":\(audioBytes),"hasTranscript":true,"hasNotes":true,"preview":"Kort.",
         "updatedAt":"\(updatedAt)"}
        """
    }

    static func detail(_ id: String, title: String = "Offerte poorten") -> String {
        let summary = recording(id, title: title)
        return String(summary.dropLast(1)) + ###","transcript":"A: Vrijdag.","notes":null,"notesMarkdown":"## Samenvatting\n\nKort."}"###
    }
}

func temporaryDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pensieve-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
@Suite(.serialized) struct PensieveModelTests {
    private func model(_ server: MockServer, outbox: Outbox, mirror: Mirror = Mirror(root: temporaryDirectory())) -> PensieveModel {
        let client = server.client()
        return PensieveModel(
            store: ConnectionStore(service: "app.burrow.pensieve.tests"), makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"),
            outbox: outbox, mirror: mirror)
    }

    private func server() -> MockServer {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/people", json: #"[{"id":"p1","name":"Eva"},{"id":"p2","name":"Ron"}]"#)
        server.on("GET", "/api/pensieve/recordings", json: "[\(Fixture.recording("r1"))]")
        server.on("GET", "/api/pensieve/recordings/r1", json: Fixture.detail("r1"))
        server.on("POST", "/api/uploads", status: 201, json: #"{"id":"u1","size":8,"received":0}"#)
        server.on("PUT", "/api/uploads/u1", json: #"{"id":"u1","size":8,"received":8}"#)
        server.on("GET", "/api/uploads/u1", json: #"{"id":"u1","size":8,"received":8}"#)
        server.on("POST", "/api/pensieve/recordings", status: 201, json: Fixture.recording("r1", status: "compressing"))
        return server
    }

    private func wav(in outbox: Outbox) throws -> URL {
        let file = try outbox.newAudioFile()
        try Data("RIFFWAVE".utf8).write(to: file)
        return file
    }

    @Test func aFinishedRecordingIsUploadedAndLeavesTheOutbox() async throws {
        let server = server()
        let outbox = Outbox(dir: temporaryDirectory())
        let model = model(server, outbox: outbox)
        await model.start()
        await model.finished(audio: try wav(in: outbox), title: "Offerte poorten", startedAt: Date())

        #expect(outbox.all().isEmpty)
        #expect(model.pending.isEmpty)
        #expect(model.selectedId == "r1")
        let created = try #require(server.requests("POST", "/api/pensieve/recordings").first)
        #expect(created.contains(#""uploadId":"u1""#))
        #expect(created.contains(#""title":"Offerte poorten""#))
        #expect(server.requests("PUT", "/api/uploads/u1").first == "RIFFWAVE")
    }

    @Test func aRecordingWaitsInTheOutboxWhenTheServerIsUnreachable() async throws {
        let server = server()
        server.on("POST", "/api/pensieve/recordings", status: 503, json: #"{"error":"down"}"#)
        let outbox = Outbox(dir: temporaryDirectory())
        let model = model(server, outbox: outbox)
        await model.start()
        await model.finished(audio: try wav(in: outbox), title: "Treingesprek", startedAt: Date())

        let waiting = try #require(outbox.all().first)
        #expect(waiting.uploadId == "u1")
        #expect(waiting.lastError != nil)
        #expect(model.error != nil)

        // Back online: the upload continues instead of starting over.
        server.on("POST", "/api/pensieve/recordings", status: 201, json: Fixture.recording("r1", status: "compressing"))
        await model.sendPending()
        #expect(outbox.all().isEmpty)
        #expect(server.requests("POST", "/api/uploads").count == 1)
    }

    @Test func aTunnelRestartDuringAnUploadRetriesQuietly() async throws {
        let server = server()
        server.on("POST", "/api/pensieve/recordings", status: 530, json: "<!doctype html><title>Cloudflare Tunnel error</title>")
        let outbox = Outbox(dir: temporaryDirectory())
        let client = server.client()
        let model = PensieveModel(
            store: ConnectionStore(service: "app.burrow.pensieve.tests"), makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"),
            outbox: outbox, mirror: Mirror(root: temporaryDirectory()),
            reachability: ServerReachability(delays: [.milliseconds(20)]))
        await model.start()
        server.on("GET", "/api/me", status: 530, json: "<html></html>")
        await model.finished(audio: try wav(in: outbox), title: "Treingesprek", startedAt: Date())

        #expect(model.error == nil)
        #expect(!model.reachability.isReachable)
        #expect(outbox.all().count == 1)

        server.on("GET", "/api/me", json: Fixture.me)
        server.on("POST", "/api/pensieve/recordings", status: 201, json: Fixture.recording("r1", status: "compressing"))
        for _ in 0..<200 where !outbox.all().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(outbox.all().isEmpty)
        #expect(model.reachability.isReachable)
        #expect(model.error == nil)
    }

    @Test func copiesFinishedRecordingsToICloudOnceAndFollowsARename() async throws {
        let server = server()
        server.on("GET", "/api/pensieve/recordings/r1/audio", json: "AAC!")
        let root = temporaryDirectory()
        let model = model(server, outbox: Outbox(dir: temporaryDirectory()), mirror: Mirror(root: root))
        await model.start()
        await model.mirrorNow()

        let folder = root.appendingPathComponent("2026-10-20_offerte-poorten")
        #expect(try String(contentsOf: folder.appendingPathComponent("notulen.md"), encoding: .utf8).contains("## Samenvatting"))
        #expect(try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8) == "A: Vrijdag.")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.m4a").path))

        await model.mirrorNow()
        #expect(server.requests("GET", "/api/pensieve/recordings/r1/audio").count == 1)

        server.on("GET", "/api/pensieve/recordings", json: "[\(Fixture.recording("r1", title: "Offerte blauwe poorten", updatedAt: "2026-10-20T11:00:00.000Z"))]")
        server.on("GET", "/api/pensieve/recordings/r1", json: Fixture.detail("r1", title: "Offerte blauwe poorten"))
        await model.mirrorNow()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-10-20_offerte-blauwe-poorten/audio.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(server.requests("GET", "/api/pensieve/recordings/r1/audio").count == 1)
    }
}

@Suite struct RecHoarderImportTests {
    private func meetings() throws -> URL {
        let root = temporaryDirectory()
        for (slug, files) in [
            ("2026-08-19_standup", ["wav", "txt", "md"]),
            ("2026-08-19_standup_1902", ["wav"]),
            ("2026-08-25_offerte_poorten", ["wav", "txt"]),
            ("notities", ["wav"]),
        ] {
            let dir = root.appendingPathComponent(slug)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for ext in files {
                try Data("\(slug).\(ext)".utf8).write(to: dir.appendingPathComponent("\(slug).\(ext)"))
            }
        }
        return root
    }

    @Test func findsRecHoarderMeetingsWithWhatTheyAlreadyHave() throws {
        let scan = RecHoarderImport(root: try meetings()).scan(skipping: [])
        #expect(scan.ready.map(\.importedFrom) == ["2026-08-19_standup", "2026-08-19_standup_1902", "2026-08-25_offerte_poorten"])
        #expect(scan.ready.map(\.title) == ["standup", "standup", "offerte poorten"])
        #expect(scan.ready[0].transcript == "2026-08-19_standup.txt")
        #expect(scan.ready[0].notesMarkdown == "2026-08-19_standup.md")
        #expect(scan.ready[1].transcript == nil)
        #expect(scan.ready.allSatisfy { $0.source == "imported" && $0.audio.hasPrefix("/") })
    }

    @Test func skipsWhatWasImportedBefore() throws {
        let scan = RecHoarderImport(root: try meetings()).scan(skipping: ["2026-08-19_standup"])
        #expect(!scan.ready.contains { $0.importedFrom == "2026-08-19_standup" })
    }

    @Test func leavesTheOriginalAudioInPlaceAfterSending() throws {
        let outbox = Outbox(dir: temporaryDirectory())
        let root = try meetings()
        let upload = try #require(RecHoarderImport(root: root).scan(skipping: []).ready.first)
        try outbox.add(upload)
        outbox.remove(upload)
        #expect(FileManager.default.fileExists(atPath: upload.audio))
        #expect(outbox.all().isEmpty)
    }
}
