import CryptoKit
import Foundation
import Testing
@testable import BurrowKit

@Suite struct DeviceLoginTests {
    /// Plays the browser and the household server: checks the login page's
    /// query, "presses Toestaan" by calling the app's loopback address, and
    /// hands out a key only for the verifier that matches the challenge.
    @Test func logsInThroughTheBrowserAndGetsADeviceKey() async throws {
        let server = MockServer()
        let challenges = Locked<[String]>([])
        server.on("POST", "/api/login/token") { request in
            let body = try! JSONDecoder().decode([String: String].self, from: request.bodyData)
            let hashed = Data(SHA256.hash(data: Data(body["verifier"]!.utf8))).base64URL
            guard body["code"] == "one-time-code", challenges.value.contains(hashed) else {
                return (400, #"{"error":"invalid or expired code"}"#)
            }
            return (200, #"{"token":"bk_devicekey","key":{"id":"k1","personId":"p1","name":"Pensieve op Testmac","prefix":"bk_device","rights":["read"],"restrictions":{},"mailboxIds":null,"lastUsedAt":null,"revokedAt":null},"person":{"id":"p1","name":"Eva"}}"#)
        }
        let client = server.client()
        let login = DeviceLogin(server: client.baseURL, app: "pensieve", device: "Testmac", session: client.session)

        let result = try await login.run { url in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value!) })
            #expect(url.path() == "/login/device")
            #expect(query["app"] == "pensieve")
            #expect(query["device"] == "Testmac")
            challenges.value.append(query["challenge"]!)
            var back = URLComponents(string: query["redirect"]!)!
            #expect(back.host == "127.0.0.1")
            back.queryItems = [URLQueryItem(name: "code", value: "one-time-code"), URLQueryItem(name: "state", value: query["state"])]
            Task { _ = try? await URLSession.shared.data(from: back.url!) }
        }
        #expect(result.token == "bk_devicekey")
        #expect(result.person.name == "Eva")
    }

    @Test func refusesAnAnswerForAnotherRequest() async throws {
        let server = MockServer()
        let client = server.client()
        let login = DeviceLogin(server: client.baseURL, app: "hedwig", device: "Testmac", session: client.session)
        await #expect(throws: LoginError.stateMismatch) {
            _ = try await login.run { url in
                let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    .queryItems!.first { $0.name == "redirect" }!.value!
                var back = URLComponents(string: redirect)!
                back.queryItems = [URLQueryItem(name: "code", value: "x"), URLQueryItem(name: "state", value: "forged-state")]
                Task { _ = try? await URLSession.shared.data(from: back.url!) }
            }
        }
    }

    @Test func namesTheDeviceWithOnlyCharactersTheServerAccepts() {
        let name = DeviceLogin.deviceName()
        #expect(!name.isEmpty && name.count <= 60)
        #expect(name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || " '’._()-".unicodeScalars.contains($0) })
    }
}

@Suite struct AppControlTests {
    private let type = AppControl.Command(
        name: "type", help: "", arguments: [.init(name: "id", help: ""), .init(name: "text", help: "")])

    @Test func fillsArgumentsInOrderAndJoinsTheRestIntoTheLast() {
        let request = AppControl.request(type, ["0/3", "Beste", "Eva,"])
        #expect(request["id"] as? String == "0/3")
        #expect(request["text"] as? String == "Beste Eva,")
    }

    @Test func acceptsNamedArguments() {
        let request = AppControl.request(type, ["text=Hallo", "0/1"])
        #expect(request["id"] as? String == "0/1")
        #expect(request["text"] as? String == "Hallo")
    }

    @Test func passesForceSeparately() {
        let restart = AppControl.Command(name: "restart", help: "", arguments: [])
        #expect(AppControl.request(restart, ["--force"])["force"] as? Bool == true)
    }
}

@Suite struct ServerEventTests {
    @Test func keepsEveryFieldAnEventCarries() {
        var parser = SSEParser()
        _ = parser.feed("event: recording.changed")
        _ = parser.feed(#"data: {"type":"recording.changed","recordingId":"r1","status":"done"}"#)
        let event = parser.feed("")
        #expect(event?.type == "recording.changed")
        #expect(event?["recordingId"] == "r1")
        #expect(event?["status"] == "done")
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension URLRequest {
    var bodyData: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
