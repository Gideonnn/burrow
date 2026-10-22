import Foundation
import Testing
@testable import HedwigCore

@MainActor
@Suite struct UnreachableServerTests {
    nonisolated private static let tunnelDown = "<!doctype html><html><title>Cloudflare Tunnel error</title><p>Error code 1033</p></html>"

    @Test func aRefreshDuringATunnelRestartRetriesQuietly() async throws {
        let server = MockServer()
        let down = Flag(true)
        server.on("GET", "/api/me") { _ in down.value ? (530, Self.tunnelDown) : (200, Fixture.me) }
        server.on("GET", "/api/mailboxes/mb1/messages") { _ in
            down.value ? (530, Self.tunnelDown) : (200, "[\(Fixture.message("m1", subject: "Eerste"))]")
        }
        server.on("GET", "/api/messages/m1", json: Fixture.message("m1", subject: "Eerste"))
        let client = server.client()
        let model = AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"),
            reachability: ServerReachability(delays: [.milliseconds(20)]))
        model.selection = .inbox(mailboxId: "mb1")

        await model.loadSelection()
        #expect(model.error == nil)
        #expect(!model.reachability.isReachable)

        down.value = false
        for _ in 0..<200 where !model.reachability.isReachable || model.messages.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.reachability.isReachable)
        #expect(model.messages.map(\.id) == ["m1"])
        #expect(model.error == nil)
    }

    @Test func anActionDuringATunnelRestartSaysSoBriefly() async throws {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("POST", "/api/messages/m1/actions", status: 530, json: Self.tunnelDown)
        let client = server.client()
        let model = AppModel(
            store: ConnectionStore(service: "app.burrow.hedwig.tests"),
            makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"),
            reachability: ServerReachability(delays: [.milliseconds(20)]))

        await model.perform([.archive], on: "m1")
        #expect(model.error == "Server even niet bereikbaar. Probeer het zo opnieuw.")
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
