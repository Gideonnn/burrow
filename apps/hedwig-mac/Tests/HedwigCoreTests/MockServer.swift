import Foundation
@testable import HedwigCore

/// A scripted Burrow server behind URLProtocol: routes map "METHOD path" to a
/// handler that returns a status and a JSON body, and every request is logged.
final class MockServer: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)

    private let lock = NSLock()
    private var routes: [String: Handler] = [:]
    private var dataRoutes: [String: Data] = [:]
    private(set) var log: [(method: String, path: String, body: String)] = []

    func on(_ method: String, _ path: String, status: Int = 200, json: String) {
        on(method, path) { _ in (status, json) }
    }

    func on(_ method: String, _ path: String, handler: @escaping Handler) {
        lock.withLock { routes["\(method) \(path)"] = handler }
    }

    /// A binary body, such as a zipped build.
    func onData(_ method: String, _ path: String, _ data: Data) {
        lock.withLock { dataRoutes["\(method) \(path)"] = data }
    }

    func requests(_ method: String, _ path: String) -> [String] {
        lock.withLock { log.filter { $0.method == method && $0.path == path }.map(\.body) }
    }

    fileprivate func respond(to request: URLRequest) -> (Int, Data) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path() ?? ""
        let body = request.httpBodyStream.map(readAll) ?? request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let (handler, data) = lock.withLock {
            log.append((method, path, body))
            return (routes["\(method) \(path)"], dataRoutes["\(method) \(path)"])
        }
        if let data { return (200, data) }
        guard let handler else { return (404, Data(#"{"error":"not found"}"#.utf8)) }
        let (status, json) = handler(request)
        return (status, Data(json.utf8))
    }

    // Each server answers on its own host, so suites running in parallel never
    // reach each other's routes.
    private let host = "\(UUID().uuidString.lowercased()).test"

    func client() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        MockProtocol.register(self, host: host)
        return APIClient(baseURL: URL(string: "http://\(host)")!, token: "bk_test", session: URLSession(configuration: config))
    }
}

private func readAll(_ stream: InputStream) -> String {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    return String(decoding: data, as: UTF8.self)
}

final class MockProtocol: URLProtocol {
    nonisolated(unsafe) private static var servers: [String: MockServer] = [:]
    private static let lock = NSLock()

    static func register(_ server: MockServer, host: String) {
        lock.withLock { servers[host] = server }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let server = Self.lock.withLock { Self.servers[request.url?.host() ?? ""] }!
        let (status, data) = server.respond(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum Fixture {
    static let me = """
    {"person":{"id":"p1","name":"Gideon"},"key":{"id":"k1","name":"MacBook Gideon"},
     "rights":["read","organize","draft","send"],
     "mailboxes":[{"id":"mb1","ownerId":"p1","provider":"gmail","address":"gideon@example.com","name":"gideon@example.com"}]}
    """

    static func message(_ id: String, subject: String, folder: String = "inbox", unread: Bool = true, flagged: Bool = false) -> String {
        """
        {"id":"\(id)","mailboxId":"mb1","threadId":"t-\(id)","from":{"name":"Marieke","email":"marieke@example.nl"},
         "to":[{"email":"gideon@example.com"}],"cc":[],"subject":"\(subject)","snippet":"Zin in eten?",
         "receivedAt":"2026-10-19T09:41:00.000Z","folder":"\(folder)","unread":\(unread),"flagged":\(flagged),
         "labels":[],"hasAttachments":false,"bodyText":"Zin in eten?","bodyHtml":null}
        """
    }
}
