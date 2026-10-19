import CryptoKit
import Foundation
import Observation

public struct ClientRelease: Codable, Equatable, Sendable {
    public var version: Int
    public var size: Int
    public var sha256: String
    public var signature: String
    public var publishedAt: String
}

extension APIClient {
    /// The latest published build of an app, or nil before anything is published.
    public func latestRelease(of client: String) async throws -> ClientRelease? {
        do {
            return try await call("GET", "api/clients/\(client)/latest")
        } catch APIError.notFound {
            return nil
        }
    }

    public func downloadRelease(of client: String, _ version: Int) async throws -> Data {
        let (bytes, response) = try await session.data(for: request("GET", "api/clients/\(client)/\(version).zip"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.notFound }
        return bytes
    }
}

/// Finds a newer build of the app on the server, checks its signature and
/// unpacks it next to the running app, ready to be swapped in on the next
/// restart.
@MainActor
@Observable
public final class Updater {
    public let currentVersion: Int
    // "hedwig" on the server, "Hedwig.app" in the zip.
    public let client: String
    public let appName: String
    public private(set) var ready: Int?
    public private(set) var lastError: String?
    public private(set) var stagedApp: URL?

    private let publicKey: String
    private let stagingDir: URL
    private let api: @MainActor () -> APIClient?
    private var checking = false

    public init(
        client: String, appName: String, currentVersion: Int, publicKey: String, stagingDir: URL,
        api: @escaping @MainActor () -> APIClient?
    ) {
        self.client = client
        self.appName = appName
        self.currentVersion = currentVersion
        self.publicKey = publicKey
        self.stagingDir = stagingDir
        self.api = api
    }

    public var enabled: Bool { !publicKey.isEmpty && currentVersion > 0 }

    public func check() async {
        guard enabled, !checking, let api = api() else { return }
        checking = true
        defer { checking = false }
        do {
            guard let release = try await api.latestRelease(of: client),
                  release.version > currentVersion, release.version != ready
            else { return }
            let zip = try await api.downloadRelease(of: client, release.version)
            try verify(zip, release)
            let app = try unpack(zip, version: release.version)
            stagedApp = app
            ready = release.version
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func verify(_ zip: Data, _ release: ClientRelease) throws {
        let sha = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard zip.count == release.size, sha == release.sha256 else {
            throw ControlError("the download of build \(release.version) is damaged")
        }
        guard let keyData = Data(base64Encoded: publicKey),
              let signature = Data(base64Encoded: release.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signature, for: zip)
        else { throw ControlError("build \(release.version) is not signed with the release key; not installing it") }
    }

    private func unpack(_ zip: Data, version: Int) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: stagingDir)
        let dir = stagingDir.appendingPathComponent("\(version)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let archive = dir.appendingPathComponent("\(appName).zip")
        try zip.write(to: archive)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, dir.path]
        try ditto.run()
        ditto.waitUntilExit()
        try? fm.removeItem(at: archive)
        let app = dir.appendingPathComponent("\(appName).app")
        guard ditto.terminationStatus == 0, fm.fileExists(atPath: app.path) else {
            throw ControlError("build \(version) did not unpack")
        }
        return app
    }

    /// A shell script that waits for this process to quit, swaps the staged
    /// build in for `target` (keeping the old one if the copy fails) and opens it.
    public func relaunchScript(target: URL, pid: Int32, open: String = "open") -> String {
        let quote = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var lines = ["while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done"]
        if let stagedApp {
            let old = quote(target.path + ".old")
            lines += [
                "rm -rf \(old)",
                "if mv \(quote(target.path)) \(old) && ditto \(quote(stagedApp.path)) \(quote(target.path)); then rm -rf \(old); else rm -rf \(quote(target.path)); mv \(old) \(quote(target.path)); fi",
                "rm -rf \(quote(stagingDir.path))",
            ]
        }
        lines.append("\(open) \(quote(target.path))")
        return lines.joined(separator: "\n") + "\n"
    }
}
