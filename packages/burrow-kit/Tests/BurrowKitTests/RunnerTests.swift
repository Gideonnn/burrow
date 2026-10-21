import Foundation
import Testing
@testable import BurrowKit

@MainActor
@Suite(.serialized) struct RunnerTests {
    /// A stand-in `claude` that records its stdin and prints a JSON envelope.
    private func fakeClaude(envelope: String, exitCode: Int32 = 0) throws -> (String, URL) {
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
        return (script.path, log)
    }

    private static func claimed(id: String = "t1", kind: String = "routine", model: String = "haiku", agent: String = "claude") -> String {
        """
        [{"task":{"id":"\(id)","kind":"\(kind)","routineId":"r1","routineName":"Factuur verwerken","skill":"invoice","bot":"kreacher",
          "where":"client","queue":"cloud","priority":"normal","model":null,"status":"running","messageId":null,"result":null,
          "error":null,"claimedBy":"MacBook","createdAt":"2026-10-19T09:00:00.000Z","updatedAt":"2026-10-19T09:00:00.000Z"},
          "request":{"model":"\(model)","system":"You are Kreacher.","prompt":"Process the invoice","schema":{"type":"object"},"agent":"\(agent)"}}]
        """
    }

    private let runners = #"""
    {"runners":[{"id":"r9","name":"MacBook","personName":"Gideon","mine":true,"queues":["cloud"],"agents":["claude"],
      "models":[],"kinds":["*"],"paused":false,"online":true,"lastSeenAt":"2026-10-19T09:00:00.000Z","doing":null}],
     "work":[{"queue":"local","kind":"hedwig.facts","title":"Mail-facts","waiting":35600,"done":12400}]}
    """#

    private func config(claude: String) -> RunnerConfig {
        var c = RunnerConfig(name: "MacBook")
        c.claudePath = claude
        return c
    }

    private let day = RunnerConditions(
        now: ISO8601DateFormatter().date(from: "2026-10-19T13:00:00Z")!, onCharger: true, installedModels: [], claude: true)

    @Test func runsAClaimedTaskWithLocalClaudeAndReportsTheAnswer() async throws {
        let server = MockServer()
        server.on("POST", "/api/runner/claim", json: Self.claimed())
        server.on("POST", "/api/runner/tasks/t1/complete", json: #"{"accepted":true}"#)
        server.on("GET", "/api/runners", json: runners)
        let (claude, log) = try fakeClaude(envelope: #"{"result":"","structured_output":{"summary":"Klaar"}}"#)

        let runner = Runner()
        let ran = await runner.runOnce(api: server.client(), config: config(claude: claude), conditions: day)

        #expect(ran == 1)
        #expect(try String(contentsOf: log, encoding: .utf8) == "Process the invoice")
        #expect(server.requests("POST", "/api/runner/tasks/t1/complete").first == #"{"summary":"Klaar"}"#)
        let claim = try #require(server.requests("POST", "/api/runner/claim").first)
        let body = try JSONSerialization.jsonObject(with: Data(claim.utf8)) as! [String: Any]
        #expect(body["queues"] as? [String] == ["cloud"])
        #expect(body["kinds"] as? [String] == ["*"])
        #expect(runner.completed == 1)
        #expect(runner.me?.id == "r9")
    }

    @Test func reportsAFailureWhenClaudeFails() async throws {
        let server = MockServer()
        server.on("POST", "/api/runner/claim", json: Self.claimed())
        server.on("POST", "/api/runner/tasks/t1/fail", json: #"{"failed":true}"#)
        let (claude, _) = try fakeClaude(envelope: "{}", exitCode: 2)

        let runner = Runner()
        await runner.runOnce(api: server.client(), config: config(claude: claude), conditions: day)
        #expect(server.requests("POST", "/api/runner/tasks/t1/fail").count == 1)
        #expect(runner.status.hasPrefix("Mislukt"))
    }

    @Test func sendsLocalRequestsToOllamaAndNeverToClaude() async throws {
        let server = MockServer()
        server.on("POST", "/api/runner/claim", json: Self.claimed(kind: "hedwig.facts", model: "ollama:gemma4:26b-a4b", agent: "local"))
        server.on("POST", "/api/runner/tasks/t1/complete", json: #"{"accepted":true}"#)
        server.on("GET", "/api/runners", json: runners)
        server.on("POST", "/api/chat", json: #"{"message":{"role":"assistant","content":"{\"category\":\"invoice\"}"}}"#)
        let (claude, log) = try fakeClaude(envelope: #"{"structured_output":{"x":1}}"#)
        let client = server.client()

        let runner = Runner(ollama: OllamaAgent(baseURL: client.baseURL, session: client.session))
        var night = day
        night.now = ISO8601DateFormatter().date(from: "2026-10-19T01:00:00Z")!
        night.installedModels = ["ollama:gemma4:26b-a4b"]
        var c = config(claude: claude)
        c.nightStart = 0
        c.nightEnd = 23 * 60 + 59
        await runner.runOnce(api: client, config: c, conditions: night)

        let chat = try #require(server.requests("POST", "/api/chat").first)
        let body = try JSONSerialization.jsonObject(with: Data(chat.utf8)) as! [String: Any]
        #expect(body["model"] as? String == "gemma4:26b-a4b")
        #expect(body["think"] as? Bool == false)
        #expect(server.requests("POST", "/api/runner/tasks/t1/complete").first == #"{"category":"invoice"}"#)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(runner.status == "Klaar: Mail-facts: 12.400 van 48.000")
    }

    @Test func keepsATaskOfTheLocalQueueOnOllamaWhateverItsRequestSays() {
        let request = AgentRequest(model: "haiku", effort: nil, system: "s", prompt: "p", schema: .object([:]), agent: "claude", timeoutMs: nil)
        #expect(Runner.usesOllama(request, queue: "local"))
        #expect(!Runner.usesOllama(request, queue: "cloud"))
    }

    @Test func offersTheLocalQueueOnlyAtNightOnTheChargerWithTheModel() {
        var c = RunnerConfig(name: "MacBook")
        c.nightStart = 23 * 60
        c.nightEnd = 7 * 60
        let at = { (iso: String) in ISO8601DateFormatter().date(from: iso)! }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        #expect(c.inNight(at("2026-10-19T23:30:00Z"), calendar: cal))
        #expect(c.inNight(at("2026-10-19T03:00:00Z"), calendar: cal))
        #expect(!c.inNight(at("2026-10-19T07:00:00Z"), calendar: cal))

        c.nightOnly = false
        var now = RunnerConditions(now: Date(), onCharger: true, installedModels: ["ollama:gemma4:26b-a4b"], claude: true)
        #expect(Runner.offer(c, now).offer.queues == ["local", "cloud"])
        #expect(Runner.offer(c, now).offer.models == ["ollama:gemma4:26b-a4b"])

        now.onCharger = false
        #expect(Runner.offer(c, now).offer.queues == ["cloud"])
        c.cloud = false
        #expect(Runner.offer(c, now) == (RunnerOffer(queues: [], agents: ["claude"], models: [], concurrency: 2), "Wacht op de lader"))

        now.onCharger = true
        now.installedModels = []
        #expect(Runner.offer(c, now).waiting == "Ollama draait niet")
        now.installedModels = ["ollama:qwen3.5:9b"]
        #expect(Runner.offer(c, now).waiting == "Model ontbreekt: ollama pull gemma4:26b-a4b")
    }

    @Test func readsAndWritesItsSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        #expect(RunnerConfig.set("nightStart", "22:30", in: defaults))
        #expect(RunnerConfig.set("chargerOnly", "uit", in: defaults))
        #expect(RunnerConfig.set("model", "qwen3.5:9b", in: defaults))
        #expect(!RunnerConfig.set("concurrency", "12", in: defaults))
        #expect(!RunnerConfig.set("colour", "red", in: defaults))
        let c = RunnerConfig.load(defaults)
        #expect(c.nightStart == 22 * 60 + 30)
        #expect(!c.chargerOnly)
        #expect(c.model == "ollama:qwen3.5:9b")
        #expect(c.concurrency == 2)
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

    @Test func explainsAMissingModel() async throws {
        let server = MockServer()
        server.on("POST", "/api/chat", status: 404, json: #"{"error":"model 'gemma4:26b-a4b' not found"}"#)
        let client = server.client()
        let ollama = OllamaAgent(baseURL: client.baseURL, session: client.session)
        let request = AgentRequest(model: "ollama:gemma4:26b-a4b", system: "s", prompt: "p", schema: .object([:]), agent: "local")
        await #expect(throws: RunnerError.ollama("Het model gemma4:26b-a4b staat niet op deze Mac: ollama pull gemma4:26b-a4b")) {
            try await ollama.run(request)
        }
    }

    @Test func saysSoWhenNotLoggedIn() async {
        let runner = Runner()
        await runner.runOnce(api: nil, config: RunnerConfig(name: "MacBook"), conditions: day)
        #expect(runner.status.hasPrefix("Niet ingelogd"))
    }
}
