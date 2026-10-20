import Foundation
import Testing
@testable import BurrowKit

@MainActor
@Suite(.serialized) struct LocalRunnerTests {
    /// A stand-in `claude` that records its stdin and prints a JSON envelope.
    private func fakeClaude(envelope: String, exitCode: Int32 = 0) throws -> (ClaudeCLI, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude")
        let log = dir.appendingPathComponent("stdin.txt")
        try """
        #!/bin/sh
        cat > "\(log.path)"
        printf '%s' '\(envelope)'
        exit \(exitCode)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (ClaudeCLI(path: script.path), log)
    }

    private let claimed = """
    [{"task":{"id":"t1","routineId":"r1","routineName":"Factuur verwerken","skill":"invoice","bot":"kreacher",
      "where":"client","status":"running","messageId":null,"result":null,"error":null,"claimedBy":"MacBook",
      "createdAt":"2026-10-19T09:00:00.000Z","updatedAt":"2026-10-19T09:00:00.000Z"},
      "request":{"model":"haiku","system":"You are Kreacher.","prompt":"Process the invoice","schema":{"type":"object"}}}]
    """

    @Test func runsAClaimedTaskWithLocalClaudeAndReportsTheAnswer() async throws {
        let server = MockServer()
        server.on("POST", "/api/runner/claim", json: claimed)
        server.on("POST", "/api/runner/tasks/t1/complete", json: #"{"accepted":true}"#)
        let (claude, log) = try fakeClaude(envelope: #"{"result":"","structured_output":{"summary":"Klaar"}}"#)

        let runner = LocalRunner()
        await runner.runOnce(api: server.client(), name: "MacBook", agent: claude)

        #expect(try String(contentsOf: log, encoding: .utf8) == "Process the invoice")
        #expect(server.requests("POST", "/api/runner/tasks/t1/complete").first == #"{"summary":"Klaar"}"#)
        #expect(runner.completed == 1)
    }

    @Test func reportsAFailureWhenClaudeFails() async throws {
        let server = MockServer()
        server.on("POST", "/api/runner/claim", json: claimed)
        server.on("POST", "/api/runner/tasks/t1/fail", json: #"{"failed":true}"#)
        let (claude, _) = try fakeClaude(envelope: "{}", exitCode: 2)

        let runner = LocalRunner()
        await runner.runOnce(api: server.client(), name: "MacBook", agent: claude)
        #expect(server.requests("POST", "/api/runner/tasks/t1/fail").count == 1)
        #expect(runner.status.hasPrefix("Mislukt"))
    }

    @Test func passesTheEffortAndRefusesLocalBots() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude"), args = dir.appendingPathComponent("args.txt")
        try """
        #!/bin/sh
        echo "$@" > "\(args.path)"
        cat > /dev/null
        printf '%s' '{"structured_output":{"ok":1}}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let claude = ClaudeCLI(path: script.path)
        var request = AgentRequest(model: "opus", effort: "high", system: "s", prompt: "p", schema: .object([:]), agent: nil, timeoutMs: nil)

        _ = try await claude.run(request)
        #expect(try String(contentsOf: args, encoding: .utf8).contains("--effort high"))

        try FileManager.default.removeItem(at: args)
        request.agent = "local"
        await #expect(throws: RunnerError.self) { try await claude.run(request) }
        #expect(!FileManager.default.fileExists(atPath: args.path))
    }

    @Test func saysSoWhenClaudeIsMissing() async {
        let runner = LocalRunner()
        await runner.runOnce(api: MockServer().client(), name: "MacBook", agent: nil)
        #expect(runner.status == RunnerError.agentNotFound.errorDescription)
    }
}
