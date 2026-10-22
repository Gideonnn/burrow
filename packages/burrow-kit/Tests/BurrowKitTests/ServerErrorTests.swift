import CoreGraphics
import Foundation
import Testing
@testable import BurrowKit

private let cloudflarePage = """
    <!doctype html>
    <html><head><title>Cloudflare Tunnel error | burrow.example.com | Cloudflare</title></head>
    <body><h1>Cloudflare Tunnel error</h1><span>Error code 1033</span>
    \(String(repeating: "<p>Ray ID and much more markup</p>\n", count: 200))
    </body></html>
    """

@Suite struct ServerErrorTests {
    private func failure(_ status: Int, _ body: String) async -> Error? {
        let server = MockServer()
        server.on("GET", "/api/me", status: status, json: body)
        do {
            _ = try await server.client().profile()
            return nil
        } catch {
            return error
        }
    }

    @Test func aTunnelErrorPageIsAShortTransientMessage() async throws {
        let error = try #require(await failure(530, cloudflarePage))
        #expect(APIError.isTransient(error))
        #expect(APIError.describe(error) == "Server even niet bereikbaar. Probeer het zo opnieuw.")
    }

    @Test(arguments: [502, 503, 504, 520, 524, 530])
    func gatewayStatusesWithoutAnErrorAreTransient(status: Int) async throws {
        let error = try #require(await failure(status, "<html>bad gateway</html>"))
        #expect(APIError.isTransient(error))
    }

    @Test func theServersOwnErrorKeepsItsMessage() async throws {
        let error = try #require(await failure(503, #"{"error":"zoeken met AI is niet beschikbaar op deze server"}"#))
        #expect(!APIError.isTransient(error))
        #expect(APIError.describe(error) == "Serverfout 503: zoeken met AI is niet beschikbaar op deze server")
    }

    @Test func anHtmlBodyNeverReachesTheMessage() async throws {
        let error = try #require(await failure(500, cloudflarePage))
        #expect(!APIError.isTransient(error))
        #expect(APIError.describe(error) == "Serverfout 500.")
    }

    @Test func connectionErrorsAreTransient() {
        #expect(APIError.isTransient(URLError(.cannotConnectToHost)))
        #expect(APIError.isTransient(URLError(.timedOut)))
        #expect(APIError.isTransient(URLError(.networkConnectionLost)))
        #expect(!APIError.isTransient(URLError(.cancelled)))
        #expect(!APIError.isTransient(APIError.unauthorized))
    }

    @Test func longTextIsCutToAFewLines() {
        let long = (1...40).map { "regel \($0)" }.joined(separator: "\n")
        let short = ErrorText.short(long)
        #expect(short.split(separator: "\n").count <= 4)
        #expect(short.hasSuffix("…"))
        #expect(ErrorText.short(String(repeating: "x", count: 2_000)).count <= 300)
        #expect(ErrorText.short("Niet gevonden.") == "Niet gevonden.")
    }
}

@MainActor
@Suite struct ServerReachabilityTests {
    @Test func retriesQuietlyUntilTheServerAnswers() async throws {
        let answers = Answers(failing: 2)
        let reachability = ServerReachability(delays: [.milliseconds(10)])
        var regained = 0
        reachability.probe = { await answers.next() }
        reachability.onRegained = { regained += 1 }

        reachability.lost()
        reachability.lost()
        #expect(!reachability.isReachable)
        for _ in 0..<200 where !reachability.isReachable { try await Task.sleep(for: .milliseconds(10)) }

        #expect(reachability.isReachable)
        #expect(regained == 1)
        #expect(await answers.calls == 3)
    }
}

private actor Answers {
    private var failing: Int
    private(set) var calls = 0
    init(failing: Int) { self.failing = failing }

    func next() -> Bool {
        calls += 1
        failing -= 1
        return failing < 0
    }
}

@Suite struct WindowFrameTests {
    private let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)

    @Test func aWindowPushedBelowTheScreenComesBack() {
        let pushed = CGRect(x: 100, y: -560, width: 1200, height: 700)
        let fitted = WindowFrame.fitted(pushed, in: screen)
        #expect(screen.contains(fitted))
        #expect(fitted.size == pushed.size)
    }

    @Test func aWindowTallerThanTheScreenShrinks() {
        let fitted = WindowFrame.fitted(CGRect(x: 0, y: -2_000, width: 1000, height: 4_000), in: screen)
        #expect(fitted == CGRect(x: 0, y: 25, width: 1000, height: 875))
    }

    @Test func aVisibleWindowStaysWhereItIs() {
        let frame = CGRect(x: 200, y: 100, width: 960, height: 600)
        #expect(WindowFrame.fitted(frame, in: screen) == frame)
    }
}
