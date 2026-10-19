import CryptoKit
import Foundation
import Network

public enum LoginError: Error, LocalizedError, Equatable {
    case cancelled
    case timedOut
    case stateMismatch
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Het inloggen is afgebroken."
        case .timedOut: "Er kwam binnen vijf minuten geen antwoord uit de browser."
        case .stateMismatch: "De browser stuurde een antwoord dat niet bij deze aanvraag hoort."
        case .refused(let why): "De server weigerde: \(why)"
        }
    }
}

public struct LoginResult: Codable, Sendable {
    public var token: String
    public var key: ApiKeySummary
    public var person: Person
}

/// Logs this app in on the household server through the browser (RFC 8252):
/// listen on a loopback port, open the server's login page with a PKCE
/// challenge, wait for the browser to come back with a one-time code, and
/// trade code and verifier for a device key. The page sits behind Cloudflare
/// Access, so the person proves who they are there; no password or key is
/// typed into the app.
public struct DeviceLogin: Sendable {
    public let server: URL
    public let app: String
    public let device: String
    let session: URLSession

    public init(server: URL, app: String, device: String = DeviceLogin.deviceName(), session: URLSession = .shared) {
        self.server = server
        self.app = app
        self.device = device
        self.session = session
    }

    /// "MacBook van Angela" as the Mac calls itself, limited to what the
    /// server accepts as a device name.
    public static func deviceName() -> String {
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let allowed = raw.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || " '’._()-".unicodeScalars.contains($0)
        }
        let name = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces)
        return String((name.isEmpty ? "Mac" : name).prefix(60))
    }

    /// Runs the whole flow; `open` shows the URL in the browser.
    public func run(open: @escaping @Sendable (URL) -> Void) async throws -> LoginResult {
        let verifier = Self.random(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.random(24)
        let callback = try await LoopbackCallback.start()
        defer { callback.stop() }

        var components = URLComponents(url: server.appendingPathComponent("login/device"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "app", value: app),
            URLQueryItem(name: "device", value: device),
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect", value: "http://127.0.0.1:\(callback.port)/callback"),
        ]
        open(components.url!)

        let answer = try await callback.wait(timeout: 300)
        guard answer["state"] == state else { throw LoginError.stateMismatch }
        guard let code = answer["code"] else { throw LoginError.cancelled }
        return try await exchange(code: code, verifier: verifier)
    }

    func exchange(code: String, verifier: String) async throws -> LoginResult {
        var request = URLRequest(url: server.appendingPathComponent("api/login/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code, "verifier": verifier])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LoginError.refused(APIClient.message(data))
        }
        return try APIClient.decoder.decode(LoginResult.self, from: data)
    }

    static func random(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A one-shot HTTP listener on 127.0.0.1 that takes the browser's redirect and
/// answers with a page saying the app can take it from here.
final class LoopbackCallback: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> LoopbackCallback {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = AsyncStream<UInt16?>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.continuation.yield(listener.port?.rawValue)
            case .failed, .cancelled: ready.continuation.yield(nil)
            default: break
            }
        }
        let holder = Holder()
        listener.newConnectionHandler = { connection in holder.callback?.handle(connection) }
        listener.start(queue: .global())
        var port: UInt16?
        for await value in ready.stream {
            port = value
            break
        }
        guard let port else { throw LoginError.refused("could not listen on this Mac") }
        let callback = LoopbackCallback(listener: listener, port: port)
        holder.callback = callback
        return callback
    }

    private final class Holder: @unchecked Sendable { var callback: LoopbackCallback? }

    func wait(timeout seconds: Double) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    if let result = self.result {
                        self.lock.unlock()
                        continuation.resume(with: result)
                    } else {
                        self.continuation = continuation
                        self.lock.unlock()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LoginError.timedOut
            }
            defer { group.cancelAll() }
            let first = try await group.next()!
            return first
        }
    }

    func stop() {
        listener.cancel()
        finish(.failure(LoginError.cancelled))
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard self.result == nil else { return lock.unlock() }
        self.result = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let line = request.split(separator: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            var query: [String: String] = [:]
            if parts.count >= 2, parts[0] == "GET", let url = URLComponents(string: String(parts[1])), url.path == "/callback" {
                for item in url.queryItems ?? [] { query[item.name] = item.value }
            }
            let ok = !query.isEmpty
            let body = ok
                ? "<!doctype html><meta charset=utf-8><title>Ingelogd</title><body style=\"font-family:-apple-system;margin:20vh auto;max-width:28rem;text-align:center\"><h1 style=\"font-size:1.3rem\">Je bent ingelogd</h1><p style=\"color:#6b655d\">Je kunt dit venster sluiten en terug naar de app.</p>"
                : "not found"
            let head = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            if ok { self?.finish(.success(query)) }
        }
    }
}
