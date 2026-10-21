import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Observation

/// How this Mac's runner works, kept in the `app.burrow.runner` defaults so
/// `burrowctl runner set` and the menu share it.
public struct RunnerConfig: Equatable, Sendable {
    public var name: String
    public var local = true
    public var cloud = true
    /// Local work only inside the night window, and only on the charger.
    public var nightOnly = true
    public var chargerOnly = true
    /// Minutes after midnight; the window may cross midnight.
    public var nightStart = 0
    public var nightEnd = 7 * 60
    public var model = "ollama:gemma4:26b-a4b"
    public var concurrency = 2
    public var claudePath = ""

    public init(name: String) { self.name = name }

    public static let suite = "app.burrow.runner"
    public static let keys = ["name", "local", "cloud", "nightOnly", "chargerOnly", "nightStart", "nightEnd", "model", "concurrency", "claudePath"]

    public static func load(_ defaults: UserDefaults = UserDefaults(suiteName: suite) ?? .standard) -> RunnerConfig {
        var c = RunnerConfig(name: defaults.string(forKey: "name") ?? DeviceLogin.deviceName())
        if defaults.object(forKey: "local") != nil { c.local = defaults.bool(forKey: "local") }
        if defaults.object(forKey: "cloud") != nil { c.cloud = defaults.bool(forKey: "cloud") }
        if defaults.object(forKey: "nightOnly") != nil { c.nightOnly = defaults.bool(forKey: "nightOnly") }
        if defaults.object(forKey: "chargerOnly") != nil { c.chargerOnly = defaults.bool(forKey: "chargerOnly") }
        if let v = defaults.string(forKey: "nightStart").flatMap(Self.minutes) { c.nightStart = v }
        if let v = defaults.string(forKey: "nightEnd").flatMap(Self.minutes) { c.nightEnd = v }
        if let v = defaults.string(forKey: "model"), !v.isEmpty { c.model = v.hasPrefix("ollama:") ? v : "ollama:\(v)" }
        if defaults.object(forKey: "concurrency") != nil { c.concurrency = min(8, max(1, defaults.integer(forKey: "concurrency"))) }
        c.claudePath = defaults.string(forKey: "claudePath") ?? ""
        return c
    }

    /// Stores one setting from `burrowctl runner set key=value`; nil when the key or value is invalid.
    public static func set(_ key: String, _ value: String, in defaults: UserDefaults = UserDefaults(suiteName: suite) ?? .standard) -> Bool {
        switch key {
        case "local", "cloud", "nightOnly", "chargerOnly":
            guard let on = ["true": true, "aan": true, "on": true, "1": true, "false": false, "uit": false, "off": false, "0": false][value.lowercased()] else { return false }
            defaults.set(on, forKey: key)
        case "nightStart", "nightEnd":
            guard minutes(value) != nil else { return false }
            defaults.set(value, forKey: key)
        case "concurrency":
            guard let n = Int(value), (1...8).contains(n) else { return false }
            defaults.set(n, forKey: key)
        case "name", "model", "claudePath":
            defaults.set(value, forKey: key)
        default:
            return false
        }
        return true
    }

    /// "07:00" or "7" as minutes after midnight.
    public static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":").map { Int($0) }
        guard let h = parts.first ?? nil, (0...23).contains(h) else { return nil }
        let m = parts.count > 1 ? (parts[1] ?? -1) : 0
        guard (0...59).contains(m), parts.count <= 2 else { return nil }
        return h * 60 + m
    }

    public static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    public var description: [(String, String)] {
        [("name", name), ("local", "\(local)"), ("cloud", "\(cloud)"), ("nightOnly", "\(nightOnly)"),
         ("chargerOnly", "\(chargerOnly)"), ("nightStart", Self.clock(nightStart)), ("nightEnd", Self.clock(nightEnd)),
         ("model", model), ("concurrency", "\(concurrency)"), ("claudePath", claudePath.isEmpty ? "(zoek zelf)" : claudePath)]
    }

    /// Whether `date` falls inside the night window.
    public func inNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if nightStart == nightEnd { return true }
        return nightStart < nightEnd ? (nightStart..<nightEnd).contains(now) : now >= nightStart || now < nightEnd
    }
}

/// The state of the Mac the runner decides on.
public struct RunnerConditions: Sendable {
    public var now: Date
    public var onCharger: Bool
    public var installedModels: [String]
    public var claude: Bool

    public init(now: Date, onCharger: Bool, installedModels: [String], claude: Bool) {
        self.now = now
        self.onCharger = onCharger
        self.installedModels = installedModels
        self.claude = claude
    }
}

public enum Power {
    /// True on mains power, and on Macs without a battery.
    public static func onCharger() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return true }
        return type == kIOPSACPowerValue
    }
}

/// Keeps the Mac awake while tasks run. A closed lid without an external
/// display still sleeps.
final class SleepAssertion {
    private var id: IOPMAssertionID = 0
    private var held = false

    func hold(_ on: Bool) {
        if on, !held {
            held = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Burrow voert taken uit" as CFString, &id) == kIOReturnSuccess
        } else if !on, held {
            IOPMAssertionRelease(id)
            held = false
        }
    }
}

/// This Mac as a runner: it claims tasks with what it offers (Claude for the
/// cloud queue, a local model through Ollama for the local queue), runs up
/// to `concurrency` at once and reports each answer. It claims again at once
/// while there is work and waits a minute otherwise; every claim is also its
/// heartbeat, so the server lists it as online.
@MainActor
@Observable
public final class Runner {
    public private(set) var status = "Wacht op taken"
    public private(set) var completed = 0
    public private(set) var failed = 0
    public private(set) var running = 0
    public private(set) var paused = false
    public private(set) var me: RunnerInfo?
    public private(set) var work: [QueueWork] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var nap: Task<Void, Never>?
    @ObservationIgnored private let awake = SleepAssertion()
    @ObservationIgnored let ollama: OllamaAgent

    public init(ollama: OllamaAgent = OllamaAgent()) { self.ollama = ollama }

    /// Which queues this Mac serves right now, or why it serves none.
    public nonisolated static func offer(_ config: RunnerConfig, _ c: RunnerConditions) -> (offer: RunnerOffer, waiting: String?) {
        var queues: [String] = []
        var models: [String] = []
        var waiting: String?
        if config.local {
            if !OllamaAgent.has(config.model, in: c.installedModels) {
                waiting = c.installedModels.isEmpty
                    ? "Ollama draait niet"
                    : "Model ontbreekt: ollama pull \(OllamaAgent.modelName(config.model))"
            } else if config.nightOnly, !config.inNight(c.now) {
                waiting = "Wacht tot de nacht (\(RunnerConfig.clock(config.nightStart)))"
            } else if config.chargerOnly, !c.onCharger {
                waiting = "Wacht op de lader"
            } else {
                queues.append("local")
                models.append(config.model)
            }
        }
        if config.cloud {
            if c.claude { queues.append("cloud") } else if queues.isEmpty { waiting = RunnerError.agentNotFound.errorDescription }
        }
        if !queues.isEmpty { waiting = nil }
        return (RunnerOffer(queues: queues, agents: c.claude ? ["claude"] : [], models: models, concurrency: config.concurrency), waiting)
    }

    /// Local requests never reach Claude, and cloud requests never Ollama.
    public nonisolated static func usesOllama(_ request: AgentRequest, queue: String? = nil) -> Bool {
        queue == "local" || request.agent == "local" || request.model.hasPrefix("ollama:")
    }

    /// Starts the loop, or wakes a waiting one so a changed setting applies
    /// now; a batch that is running is never interrupted.
    public func start(
        api: @escaping @MainActor () -> APIClient?, config: @escaping @MainActor () -> RunnerConfig,
        onChange: @escaping @MainActor () -> Void = {}
    ) {
        if loop != nil {
            nap?.cancel()
            return
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let claimed = await self.runOnce(api: api(), config: config())
                onChange()
                if claimed == 0 {
                    let wait = Task { _ = try? await Task.sleep(nanoseconds: 60 * 1_000_000_000) }
                    self.nap = wait
                    await wait.value
                    self.nap = nil
                }
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        nap?.cancel()
        awake.hold(false)
        status = "Uit"
    }

    /// One claim with the Mac as it is now; returns how many tasks ran.
    @discardableResult
    public func runOnce(api: APIClient?, config: RunnerConfig, conditions: RunnerConditions? = nil) async -> Int {
        guard let api else {
            status = "Niet ingelogd: burrowctl runner login"
            return 0
        }
        let claude = ClaudeCLI.find(override: config.claudePath.isEmpty ? nil : config.claudePath)
        let c: RunnerConditions
        if let conditions {
            c = conditions
        } else {
            c = RunnerConditions(now: Date(), onCharger: Power.onCharger(), installedModels: await ollama.installedModels(), claude: claude != nil)
        }
        let (offer, waiting) = Self.offer(config, c)
        guard !offer.queues.isEmpty else {
            await refresh(api: api, name: config.name)
            status = waiting ?? "Lokaal en cloud staan uit"
            return 0
        }
        let claimed: [ClaimedTask]
        do {
            claimed = try await api.claim(runner: config.name, kinds: ["*"], offer: offer, max: offer.concurrency)
        } catch {
            status = "Server: \(error.localizedDescription)"
            return 0
        }
        await refresh(api: api, name: config.name)
        guard !claimed.isEmpty else {
            status = paused ? "Gepauzeerd" : waiting ?? "Wacht op taken"
            return 0
        }
        running = claimed.count
        status = "Bezig: \(progress(for: claimed[0]))"
        awake.hold(true)
        defer { awake.hold(false) }
        let ollama = self.ollama
        let results = await withTaskGroup(of: Bool.self) { group in
            for next in claimed {
                group.addTask {
                    do {
                        let agent: AgentRunning
                        if Self.usesOllama(next.request, queue: next.task.queue) {
                            agent = ollama
                        } else if let claude {
                            agent = claude
                        } else {
                            throw RunnerError.agentNotFound
                        }
                        let answer = try await agent.run(next.request)
                        try await api.complete(task: next.task.id, answer: answer)
                        return true
                    } catch {
                        try? await api.fail(task: next.task.id, error: error.localizedDescription)
                        return false
                    }
                }
            }
            var all: [Bool] = []
            for await ok in group { all.append(ok) }
            return all
        }
        running = 0
        completed += results.filter { $0 }.count
        failed += results.filter { !$0 }.count
        status = results.allSatisfy { $0 } ? "Klaar: \(progress(for: claimed[0]))" : "Mislukt: \(claimed[0].task.displayTitle)"
        return claimed.count
    }

    private func progress(for claimed: ClaimedTask) -> String {
        work.first { $0.kind == claimed.task.kind }?.progress ?? claimed.task.displayTitle
    }

    private func refresh(api: APIClient, name: String) async {
        guard let response = try? await api.runners() else { return }
        me = response.runners.first { $0.mine && $0.name == name }
        paused = me?.paused ?? false
        work = response.work
    }

    /// Pauses or resumes this runner on the server; the server hands a paused runner nothing.
    public func setPaused(_ on: Bool, api: APIClient?) async throws {
        guard let api, let id = me?.id else { return }
        me = try await api.setRunner(id: id, paused: on)
        paused = on
        status = on ? "Gepauzeerd" : "Wacht op taken"
    }
}
