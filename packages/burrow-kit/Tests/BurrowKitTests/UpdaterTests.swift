import CryptoKit
import Foundation
import Testing
@testable import BurrowKit

@MainActor
@Suite(.serialized) struct UpdaterTests {
    private let key = Curve25519.Signing.PrivateKey()

    /// A zipped Hedwig.app holding one file, as the release script makes it.
    private func build(_ marker: String) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = dir.appendingPathComponent("Hedwig.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: app.appendingPathComponent("marker"))
        let zip = dir.appendingPathComponent("Hedwig.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", dir.appendingPathComponent("Hedwig.app").path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    private func release(_ version: Int, _ zip: Data, signedBy signer: Curve25519.Signing.PrivateKey? = nil) throws -> String {
        let sha = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        let signature = try (signer ?? key).signature(for: zip).base64EncodedString()
        return #"{"version":\#(version),"size":\#(zip.count),"sha256":"\#(sha)","signature":"\#(signature)","publishedAt":"2026-10-19T20:00:00Z"}"#
    }

    private func updater(_ server: MockServer, current: Int = 41) -> (Updater, URL) {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("updates-\(UUID().uuidString)")
        let client = server.client()
        let updater = Updater(
            client: "hedwig", appName: "Hedwig", currentVersion: current,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
            stagingDir: staging,
            api: { client })
        return (updater, staging)
    }

    @Test func stagesANewerSignedBuild() async throws {
        let server = MockServer()
        let zip = try build("v42")
        server.on("GET", "/api/clients/hedwig/latest", json: try release(42, zip))
        server.onData("GET", "/api/clients/hedwig/42.zip", zip)
        let (updater, _) = updater(server)
        await updater.check()
        #expect(updater.lastError == nil)
        #expect(updater.ready == 42)
        let staged = try #require(updater.stagedApp)
        #expect(try String(contentsOf: staged.appendingPathComponent("Contents/marker"), encoding: .utf8) == "v42")
    }

    @Test func leavesAnOlderOrEqualBuildAlone() async throws {
        let server = MockServer()
        let zip = try build("v41")
        server.on("GET", "/api/clients/hedwig/latest", json: try release(41, zip))
        let (updater, _) = updater(server, current: 41)
        await updater.check()
        #expect(updater.ready == nil)
        #expect(server.requests("GET", "/api/clients/hedwig/41.zip").isEmpty)
    }

    @Test func refusesABuildSignedWithAnotherKey() async throws {
        let server = MockServer()
        let zip = try build("evil")
        server.on("GET", "/api/clients/hedwig/latest", json: try release(42, zip, signedBy: Curve25519.Signing.PrivateKey()))
        server.onData("GET", "/api/clients/hedwig/42.zip", zip)
        let (updater, staging) = updater(server)
        await updater.check()
        #expect(updater.ready == nil)
        #expect(updater.lastError != nil)
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("42").path))
    }

    @Test func nothingPublishedIsNotAnError() async throws {
        let server = MockServer()
        server.on("GET", "/api/clients/hedwig/latest", status: 404, json: #"{"error":"nothing published yet"}"#)
        let (updater, _) = updater(server)
        await updater.check()
        #expect(updater.ready == nil)
        #expect(updater.lastError == nil)
    }

    @Test func theRelaunchScriptSwapsTheStagedBuildIn() async throws {
        let server = MockServer()
        let zip = try build("v42")
        server.on("GET", "/api/clients/hedwig/latest", json: try release(42, zip))
        server.onData("GET", "/api/clients/hedwig/42.zip", zip)
        let (updater, staging) = updater(server)
        await updater.check()

        let target = FileManager.default.temporaryDirectory.appendingPathComponent("installed-\(UUID().uuidString)/Hedwig.app")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("v41".utf8).write(to: target.appendingPathComponent("Contents/marker"))
        let script = updater.relaunchScript(target: target, pid: 999_999, open: "true")
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", script]
        try sh.run()
        sh.waitUntilExit()

        #expect(sh.terminationStatus == 0)
        #expect(try String(contentsOf: target.appendingPathComponent("Contents/marker"), encoding: .utf8) == "v42")
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: target.path + ".old"))
    }
}
