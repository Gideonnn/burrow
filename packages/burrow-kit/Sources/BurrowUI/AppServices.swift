import AppKit
import BurrowKit
import Foundation

/// A setting of the app on this Mac (not on the server) that an agent may
/// read and change, such as whether this Mac runs tasks.
public struct LocalSetting {
    public var name: String
    public var help: String
    public var get: @MainActor () -> String
    public var set: @MainActor (String) throws -> Void

    public init(name: String, help: String, get: @escaping @MainActor () -> String, set: @escaping @MainActor (String) throws -> Void) {
        self.name = name
        self.help = help
        self.get = get
        self.set = set
    }
}

/// What every Burrow app runs next to its own model: signed updates from the
/// server, a clean restart, and the control socket through which agents on
/// this Mac operate the app (`burrowctl <app> …`). The standard commands are
/// the same in every app; the app adds its own.
@MainActor
public final class AppServices {
    public let app: String
    public let appName: String
    public let updater: Updater
    public private(set) var control: ControlService?
    private var socket: ControlSocketServer?
    private var localSettings: [LocalSetting] = []
    private let api: @MainActor () -> APIClient?

    public init(app: String, appName: String, api: @escaping @MainActor () -> APIClient?) {
        self.app = app
        self.appName = appName
        self.api = api
        updater = Updater(
            client: app, appName: appName, currentVersion: Self.installedBuild, publicKey: ReleaseKey.publicKey,
            stagingDir: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/\(appName)/Updates"),
            api: api)
    }

    /// The build number of this .app; 0 when running outside a bundle, which
    /// turns updates off for development runs.
    static var installedBuild: Int {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return 0 }
        return Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    public func addLocalSetting(_ setting: LocalSetting) { localSettings.append(setting) }

    /// Looks for a newer build now and then every hour.
    public func startUpdates() {
        Task { [updater] in
            while !Task.isCancelled {
                await updater.check()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Opens the control socket. `state` is what `<app> state` answers;
    /// `busy` tells why a restart should wait (a message being written).
    public func startControl(
        state: @escaping @MainActor () -> Any, busy: @escaping @MainActor () -> String? = { nil },
        onError: @escaping @MainActor (String) -> Void = { _ in },
        configure: (ControlService) -> Void = { _ in }
    ) {
        let service = ControlService(surface: AccessibilitySurface(), state: state, approve: approveControlAction)
        registerStandard(on: service, busy: busy, onError: onError)
        configure(service)
        control = service
        do {
            socket = try ControlSocketServer(path: ControlSocket.path(for: app)) { request in await service.handle(request) }
        } catch {
            NSLog("\(appName) control socket unavailable: \(error.localizedDescription)")
        }
    }

    public func stop() { socket?.stop() }

    private func registerStandard(
        on service: ControlService, busy: @escaping @MainActor () -> String?,
        onError: @escaping @MainActor (String) -> Void
    ) {
        let api = api
        let updater = updater
        service.register("settings", help: "The person's settings on the server and this app's settings on this Mac, with what each means.") { [weak self] _ in
            var out: [String: Any] = [
                "local": (self?.localSettings ?? []).map { ["name": $0.name, "help": $0.help, "value": $0.get()] },
            ]
            if let api = api() {
                let schema = try await api.settingsSchema()
                let values = try await api.settings()
                out["server"] = schema.map { d in
                    [
                        "name": d.key, "label": d.label, "help": d.description ?? "", "type": d.type.rawValue,
                        "options": (d.options ?? []).map(\.value), "value": Self.plain(values[d.key] ?? .null),
                    ] as [String: Any]
                }
            }
            return out
        }
        service.register(
            "set_setting", help: "Change one setting: a server setting from `settings` (true, false, an option, text, or null for the default) or a local one.",
            arguments: [.init("name", "the setting's name"), .init("value", "the new value")]
        ) { [weak self] request in
            let name = request["name"] as? String ?? ""
            let raw = request["value"] as? String ?? ""
            if let local = self?.localSettings.first(where: { $0.name == name }) {
                try local.set(raw)
                return ["name": name, "value": local.get()]
            }
            guard let api = api() else { throw ControlError("not logged in") }
            guard let definition = try await api.settingsSchema().first(where: { $0.key == name }) else {
                throw ControlError("no setting \(name); see `settings`")
            }
            let value: SettingValue = switch (definition.type, raw) {
            case (_, "null"): .null
            case (.boolean, "true"), (.boolean, "aan"): .bool(true)
            case (.boolean, "false"), (.boolean, "uit"): .bool(false)
            case (.boolean, _): throw ControlError("\(name) is true or false")
            default: .string(raw)
            }
            let values = try await api.updateSettings([name: value])
            return ["name": name, "value": Self.plain(values[name] ?? .null)]
        }
        service.register("tasks", help: "What the bots did and are doing for this person, newest first.") { _ in
            guard let api = api() else { throw ControlError("not logged in") }
            return try await api.tasks().prefix(25).map { task in
                [
                    "id": task.id, "title": task.displayTitle, "status": task.status, "bot": task.bot,
                    "summary": task.result?.summary ?? "", "error": task.error ?? "",
                ] as [String: Any]
            }
        }
        service.register("update", help: "Look for a newer signed build and get it ready.") { _ in
            await updater.check()
            return [
                "installed": updater.currentVersion,
                "ready": updater.ready as Any? ?? NSNull(),
                "error": updater.lastError as Any? ?? NSNull(),
            ] as [String: Any]
        }
        service.register("restart", help: "Quit and start again, installing a ready update; pass force while something is being written.", arguments: []) { [weak self] request in
            if let reason = busy(), request["force"] as? Bool != true {
                throw ControlError("\(reason); ask the person, or pass force")
            }
            // Answer first, then quit.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self?.restart(onError: onError)
            }
            return ["restarting": true, "installing": updater.ready as Any? ?? NSNull()] as [String: Any]
        }
    }

    static func plain(_ value: SettingValue) -> Any {
        switch value {
        case .bool(let v): v
        case .string(let v): v
        case .null: NSNull()
        }
    }

    /// Quits and starts again, swapping in a staged update if there is one.
    public func restart(onError: @escaping @MainActor (String) -> Void = { _ in }) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("\(app)-restart.sh")
        do {
            try updater.relaunchScript(target: Bundle.main.bundleURL, pid: ProcessInfo.processInfo.processIdentifier)
                .write(to: script, atomically: true, encoding: .utf8)
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = [script.path]
            sh.standardOutput = FileHandle.nullDevice
            sh.standardError = FileHandle.nullDevice
            try sh.run()
            NSApp.terminate(nil)
        } catch {
            onError("Herstarten lukte niet: \(error.localizedDescription)")
        }
    }
}

/// The server address every Burrow app on this Mac last used, so the second
/// app does not ask for it again. Not a secret; each app keeps its own key.
public enum SharedServer {
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: "app.burrow.shared")

    public static var last: URL? {
        get { defaults?.string(forKey: "serverURL").flatMap(URL.init(string:)) }
        set { defaults?.set(newValue?.absoluteString, forKey: "serverURL") }
    }
}
