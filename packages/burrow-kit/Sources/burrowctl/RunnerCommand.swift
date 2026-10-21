import AppKit
import BurrowKit
import Foundation

let runnerUsage = """
usage: burrowctl runner <command>
  login [server-url]            log this Mac in as a runner (a key with only read and tasks)
  login <server-url> --token-stdin
                                use a key made with the server CLI instead, read from stdin
  install | uninstall           start the runner at login under launchd, or remove it
  run                           run in the foreground, with a menu bar icon
  on | off                      resume or pause this Mac's runner on the server
  status                        the household's runners and the work waiting for you
  config                        this Mac's runner settings
  set <key>=<value>             change one: \(RunnerConfig.keys.joined(separator: ", "))
"""

enum RunnerCommand {
    static let store = ConnectionStore(app: "runner")
    static let label = "app.burrow.runner"
    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func main(_ args: [String]) {
        switch args.first {
        case "login" where args.contains("--token-stdin"):
            loginWithToken(args.dropFirst().first { $0 != "--token-stdin" })
        case "login": login(args.dropFirst().first)
        case "install": install()
        case "uninstall": uninstall()
        case "run":
            setvbuf(stdout, nil, _IOLBF, 0)
            MainActor.assumeIsolated { RunnerApp.run() }
        case "on", "off": pause(args.first == "off")
        case "status": status()
        case "config":
            for (key, value) in RunnerConfig.load().description { print("\(key)=\(value)") }
        case "set":
            for pair in args.dropFirst() {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, RunnerConfig.set(parts[0], parts[1]) else { fail("ongeldig: \(pair)\n\n\(runnerUsage)") }
            }
            print("bewaard; de runner gebruikt het bij de volgende ronde")
        default: fail(runnerUsage)
        }
    }

    static func api() -> APIClient? {
        store.load().map { APIClient(baseURL: $0.serverURL, token: $0.token) }
    }

    static func login(_ server: String?) {
        guard let url = server.flatMap(URL.init(string:)) ?? SharedServer.last else {
            fail("geef het serveradres: burrowctl runner login https://burrow.example.com")
        }
        do {
            let result = try blocking {
                try await DeviceLogin(server: url, app: "runner").run { link in
                    print("Open in de browser als die niet vanzelf opent:\n\(link.absoluteString)")
                    NSWorkspace.shared.open(link)
                }
            }
            try store.save(Connection(serverURL: url, token: result.token))
            print("ingelogd als \(result.person.name) met de sleutel \"\(result.key.name)\"")
        } catch {
            fail(error.localizedDescription, code: 2)
        }
    }

    // For a Mac nobody sits at: the key comes from `cli.sh create-key` on the
    // server, piped in, so it never shows on screen.
    static func loginWithToken(_ server: String?) {
        guard let url = server.flatMap(URL.init(string:)) ?? SharedServer.last else {
            fail("geef het serveradres: burrowctl runner login https://burrow.example.com --token-stdin")
        }
        let token = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { fail("geen sleutel op stdin") }
        do {
            let me = try blocking { try await APIClient(baseURL: url, token: token).profile() }
            guard me.can(.tasks) else { fail("deze sleutel mist het recht tasks") }
            try store.save(Connection(serverURL: url, token: token))
            print("ingelogd als \(me.person.name) met de sleutel \"\(me.key.name)\"")
        } catch {
            fail(error.localizedDescription, code: 2)
        }
    }

    static func install() {
        guard store.load() != nil else { fail("log eerst in: burrowctl runner login") }
        // argv[0] is a bare name when started from PATH, so ask the system.
        let me = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.resolvingSymlinksInPath().path
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/burrow-runner.log").path
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [me, "runner", "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Background",
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
        do {
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            try data.write(to: plist)
        } catch {
            fail("kon \(plist.path) niet schrijven: \(error.localizedDescription)")
        }
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        guard launchctl(["bootstrap", "gui/\(getuid())", plist.path]) else { fail("launchctl bootstrap faalde") }
        print("de runner start nu en bij elke login; log: \(log)")
    }

    static func uninstall() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plist)
        print("de runner is verwijderd")
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func pause(_ on: Bool) {
        guard let api = api() else { fail("log eerst in: burrowctl runner login") }
        let name = RunnerConfig.load().name
        do {
            let response = try blocking { try await api.runners() }
            guard let mine = response.runners.first(where: { $0.mine && $0.name == name }) else {
                fail("de server kent \"\(name)\" nog niet; start de runner met burrowctl runner install")
            }
            _ = try blocking { try await api.setRunner(id: mine.id, paused: on) }
            print(on ? "\(name) is gepauzeerd" : "\(name) staat aan")
        } catch {
            fail(error.localizedDescription, code: 2)
        }
    }

    static func status() {
        guard let api = api() else { fail("log eerst in: burrowctl runner login") }
        do {
            let response = try blocking { try await api.runners() }
            print("Runners")
            for r in response.runners {
                let state = [r.online ? "online" : "offline", r.paused ? "gepauzeerd" : "aan", r.queues.joined(separator: ", ")]
                print("  \(r.name)\(r.personName.map { " (\($0))" } ?? ""): \(state.joined(separator: " · "))\(r.doing.map { " · \($0)" } ?? "")")
            }
            print(response.work.isEmpty ? "Geen werk in de wachtrij" : "Werk")
            for w in response.work { print("  \(w.progress) (\(w.queue == "local" ? "lokaal" : "cloud"))") }
        } catch {
            fail(error.localizedDescription, code: 2)
        }
    }
}

/// Runs async work from the synchronous command line.
final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

/// The runner in the foreground: the loop plus a menu bar icon to switch it.
@MainActor
final class RunnerApp: NSObject, NSMenuDelegate {
    let runner = Runner()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    // Loaded once at launch, so a rebuilt binary never asks for the Keychain at night.
    let api = RunnerCommand.api()
    var lastStatus = ""

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = RunnerApp()
        delegate.begin()
        withExtendedLifetime(delegate) { app.run() }
    }

    func begin() {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if api == nil { print("niet ingelogd: burrowctl runner login") }
        restart()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcon() }
        }
        refreshIcon()
    }

    func restart() {
        runner.start(api: { [weak self] in self?.api }, config: { RunnerConfig.load() }, onChange: { [weak self] in self?.refreshIcon() })
    }

    func refreshIcon() {
        let symbol = runner.paused ? "pause.circle" : runner.running > 0 ? "gearshape.2.fill" : "gearshape.2"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Burrow-runner")
        item.button?.toolTip = runner.status
        if runner.status != lastStatus {
            lastStatus = runner.status
            print("\(ISO8601DateFormatter().string(from: Date())) \(runner.status)")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

    func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = RunnerConfig.load()
        let info = NSMenuItem(title: runner.status, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        for w in runner.work {
            let line = NSMenuItem(title: w.progress, action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())
        menu.addItem(toggle("Aan", on: !runner.paused, #selector(togglePaused)))
        menu.addItem(toggle("Alleen 's nachts aan de lader", on: config.nightOnly && config.chargerOnly, #selector(toggleNight)))
        menu.addItem(toggle("Lokaal (\(OllamaAgent.modelName(config.model)))", on: config.local, #selector(toggleLocal)))
        menu.addItem(toggle("Cloud (Claude)", on: config.cloud, #selector(toggleCloud)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Stoppen", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func toggle(_ title: String, on: Bool, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc func togglePaused() {
        let paused = !runner.paused
        Task {
            try? await runner.setPaused(paused, api: api)
            refreshIcon()
            if !paused { restart() }
        }
    }

    @objc func toggleNight() {
        let c = RunnerConfig.load()
        let on = !(c.nightOnly && c.chargerOnly)
        _ = RunnerConfig.set("nightOnly", "\(on)")
        _ = RunnerConfig.set("chargerOnly", "\(on)")
        restart()
    }

    @objc func toggleLocal() {
        _ = RunnerConfig.set("local", "\(!RunnerConfig.load().local)")
        restart()
    }

    @objc func toggleCloud() {
        _ = RunnerConfig.set("cloud", "\(!RunnerConfig.load().cloud)")
        restart()
    }

    @objc func quit() {
        runner.stop()
        NSApp.terminate(nil)
    }
}
