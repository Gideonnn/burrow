import HedwigCore
import SwiftUI

@main
struct HedwigApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        WindowGroup("Hedwig", id: "main") {
            RootView()
                .environment(model)
                .environment(delegate.updater)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands { HedwigCommands(model: model) }

        WindowGroup("Nieuw bericht", for: ComposeDraft.self) { $draft in
            if let draft = Binding($draft) {
                ComposeView(draft: draft)
                    .environment(model)
                    .frame(minWidth: 560, minHeight: 420)
            }
        }
        .defaultSize(width: 640, height: 520)

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 620, height: 520)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.connection == nil {
                ConnectView()
            } else {
                MainView()
            }
        }
        .alert(
            "Er ging iets mis",
            isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } }),
            actions: { Button("OK") { model.error = nil } },
            message: { Text(model.error ?? "") }
        )
    }
}

struct HedwigCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Nieuw bericht") { if let d = model.newMessage() { openWindow(value: d) } }
                .keyboardShortcut("n")
        }
        CommandMenu("Bericht") {
            Button("Antwoord") { if let d = model.reply() { openWindow(value: d) } }
                .keyboardShortcut("r")
            Button("Allen antwoorden") { if let d = model.reply(all: true) { openWindow(value: d) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Stuur door") { if let d = model.forward() { openWindow(value: d) } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Archiveer") { Task { await model.perform([.archive]) } }
                .keyboardShortcut("a", modifiers: [.command, .control])
            Button("Verwijder") { Task { await model.perform([.trash]) } }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Markeer als spam") { Task { await model.perform([.moveToSpam, .markRead]) } }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button("Gelezen of ongelezen") { Task { await model.toggleRead() } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Markeer met vlag") { Task { await model.toggleFlag() } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Vernieuw") { Task { await model.refresh() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}

/// Owns the model and starts it at launch, not when a window appears: the
/// runner and live updates keep going with every window closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()
    @MainActor lazy var updater: Updater = {
        let model = model
        return Updater(
            currentVersion: Self.installedBuild,
            publicKey: ReleaseKey.publicKey,
            stagingDir: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Hedwig/Updates"),
            api: { model.api })
    }()
    private var control: ControlSocketServer?

    /// The build number of this .app; 0 when running outside a bundle, which
    /// turns updates off for development runs.
    private static var installedBuild: Int {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return 0 }
        return Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            if model.connection != nil { await model.start() }
        }
        Task { @MainActor in startControl() }
        Task { @MainActor [updater] in
            while !Task.isCancelled {
                await updater.check()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Quits and starts again, swapping in a staged update if there is one.
    @MainActor func restart() {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("hedwig-restart.sh")
        let target = Bundle.main.bundleURL
        do {
            try updater.relaunchScript(target: target, pid: ProcessInfo.processInfo.processIdentifier)
                .write(to: script, atomically: true, encoding: .utf8)
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = [script.path]
            sh.standardOutput = FileHandle.nullDevice
            sh.standardError = FileHandle.nullDevice
            try sh.run()
            NSApp.terminate(nil)
        } catch {
            model.error = "Herstarten lukte niet: \(error.localizedDescription)"
        }
    }

    /// Lets agents on this Mac operate Hedwig with `hedwigctl`.
    @MainActor private func startControl() {
        let model = model
        let service = ControlService(surface: AccessibilitySurface(), state: { model.controlState() }, approve: approveControlAction)
        service.register("show") { request in
            try await model.show(request["text"] as? String ?? "inbox")
            return model.controlState()
        }
        service.register("open") { request in
            try await model.open(messageId: request["id"] as? String ?? "")
            return model.controlState()
        }
        let updater = updater
        service.register("update") { _ in
            await updater.check()
            return [
                "installed": updater.currentVersion,
                "ready": updater.ready as Any? ?? NSNull(),
                "error": updater.lastError as Any? ?? NSNull(),
            ] as [String: Any]
        }
        service.register("restart") { [weak self] request in
            if model.composing > 0, request["force"] as? Bool != true {
                throw ControlError("a message is being written; ask the person, or pass force")
            }
            // Answer first, then quit.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self?.restart()
            }
            return ["restarting": true, "installing": updater.ready as Any? ?? NSNull()] as [String: Any]
        }
        do {
            control = try ControlSocketServer { request in await service.handle(request) }
        } catch {
            NSLog("Hedwig control socket unavailable: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) { control?.stop() }

    // Closing the last window keeps Hedwig (and its runner) running, like Mail.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
