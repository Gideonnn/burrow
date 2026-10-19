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
    private var control: ControlSocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            if model.connection != nil { await model.start() }
        }
        Task { @MainActor in startControl() }
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
