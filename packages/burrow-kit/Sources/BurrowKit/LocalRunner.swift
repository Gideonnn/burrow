import Foundation
import Observation

public enum RunnerError: Error, LocalizedError, Equatable {
    case agentNotFound
    case agentFailed(String)
    case invalidAnswer

    public var errorDescription: String? {
        switch self {
        case .agentNotFound: "Claude Code is niet gevonden op deze Mac."
        case .agentFailed(let m): "Claude Code faalde: \(m)"
        case .invalidAnswer: "Claude Code gaf geen bruikbaar antwoord."
        }
    }
}

/// Runs one agent request with the Claude Code CLI logged in on this Mac, in
/// the same headless way as the server: no tools, no MCP servers, a JSON
/// schema for the answer. Returns the answer as raw JSON for the server to
/// validate.
public struct ClaudeCLI: Sendable {
    public let path: String

    /// GUI apps do not inherit the shell PATH, so the usual install places are
    /// checked explicitly.
    public static func find(override: String? = nil) -> ClaudeCLI? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [override, "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }.map(ClaudeCLI.init(path:))
    }

    public init(path: String) { self.path = path }

    public func run(_ request: AgentRequest) async throws -> Data {
        // A local bot's request must never reach a cloud model.
        guard request.agent != "local" else { throw RunnerError.agentFailed("lokale taak, niet voor Claude") }
        let schema = String(decoding: try JSONEncoder().encode(request.schema), as: UTF8.self)
        let arguments = [
            "-p", "--model", request.model, "--output-format", "json", "--tools", "",
            "--strict-mcp-config", "--no-session-persistence", "--system-prompt", request.system,
            "--json-schema", schema,
        ] + (request.effort.map { ["--effort", $0] } ?? [])
        let output = try await Self.exec(path, arguments, input: Data(request.prompt.utf8))
        struct Envelope: Decodable { var is_error: Bool?; var result: String?; var structured_output: JSONValue? }
        let envelope = try JSONDecoder().decode(Envelope.self, from: output)
        if envelope.is_error == true { throw RunnerError.agentFailed(envelope.result ?? "onbekend") }
        if let structured = envelope.structured_output { return try JSONEncoder().encode(structured) }
        guard var text = envelope.result?.trimmingCharacters(in: .whitespacesAndNewlines) else { throw RunnerError.invalidAnswer }
        if text.hasPrefix("```") {
            text = text.split(separator: "\n").dropFirst().joined(separator: "\n")
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
        }
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil else { throw RunnerError.invalidAnswer }
        return Data(text.utf8)
    }

    static func exec(_ path: String, _ arguments: [String], input: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { p in
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                if p.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let message = String(decoding: err.prefix(500), as: UTF8.self)
                    continuation.resume(throwing: RunnerError.agentFailed("exit \(p.terminationStatus): \(message)"))
                }
            }
            do {
                try process.run()
                stdin.fileHandleForWriting.write(input)
                try stdin.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Claims tasks meant for this Mac while the app is open, runs them one at a
/// time, and reports the result. Each app claims only the task kinds it knows.
/// Stops when the app quits; the server gives a task back to the queue if a
/// run never reports.
@MainActor
@Observable
public final class LocalRunner {
    public private(set) var status = "Wacht op taken"
    public private(set) var completed = 0
    @ObservationIgnored private var loop: Task<Void, Never>?

    public init() {}

    public func start(
        api: @escaping @MainActor () -> APIClient?, name: String, kinds: [String] = ["routine"],
        agent: @escaping @MainActor () -> ClaudeCLI?, onChange: @escaping @MainActor () -> Void
    ) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runOnce(api: api(), name: name, kinds: kinds, agent: agent())
                onChange()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        status = "Uit"
    }

    public func runOnce(api: APIClient?, name: String, kinds: [String] = ["routine"], agent: ClaudeCLI?) async {
        guard let api else { return }
        guard let agent else {
            status = RunnerError.agentNotFound.errorDescription!
            return
        }
        guard let claimed = try? await api.claim(runner: name, kinds: kinds), let next = claimed.first else {
            status = "Wacht op taken"
            return
        }
        status = "Bezig: \(next.task.displayTitle)"
        do {
            let answer = try await agent.run(next.request)
            try await api.complete(task: next.task.id, answer: answer)
            completed += 1
            status = "Klaar: \(next.task.displayTitle)"
        } catch {
            try? await api.fail(task: next.task.id, error: error.localizedDescription)
            status = "Mislukt: \(next.task.displayTitle)"
        }
    }
}
