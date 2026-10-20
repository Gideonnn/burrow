import BurrowUI
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
                .environment(delegate.services.updater)
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
                LoginView(appName: "Hedwig", app: "hedwig", accent: BurrowColor.hedwig) { url, token in
                    try await model.connect(serverURL: url, token: token)
                }
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
            Button("Zoek") { model.searchFocusRequest += 1 }
                .keyboardShortcut("f")
            Button("Vernieuw") { Task { await model.refresh() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}

/// Owns the model and starts it at launch, not when a window appears: the
/// runner and live updates keep going with every window closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()
    @MainActor lazy var services: AppServices = {
        let model = model
        return AppServices(app: "hedwig", appName: "Hedwig", api: { model.api })
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            if model.connection != nil { await model.start() }
        }
        Task { @MainActor in startControl() }
        Task { @MainActor in services.startUpdates() }
    }

    @MainActor func restart() {
        services.restart { [model] in model.error = $0 }
    }

    /// Lets agents on this Mac operate Hedwig with `burrowctl hedwig` (or
    /// `hedwigctl`) and the `burrowctl mcp` tools.
    @MainActor private func startControl() {
        let model = model
        services.addLocalSetting(LocalSetting(
            name: "runner", help: "Whether this Mac runs bot tasks meant for it while Hedwig is open (on or off).",
            get: { model.runsTasks ? "on" : "off" },
            set: { value in
                guard ["on", "off"].contains(value) else { throw ControlError("runner is on or off") }
                model.runsTasks = value == "on"
            }))
        services.startControl(
            state: { model.controlState() },
            busy: { model.composing > 0 ? "a message is being written" : nil },
            onError: { model.error = $0 }
        ) { service in
            service.register(
                "show", help: "Show a list: inbox, inbox:<address>, private, work, school, filtered, drafts, tasks, archive, sent or spam.",
                arguments: [.init("text", "where to go")]
            ) { request in
                try await model.show(request["text"] as? String ?? "inbox")
                return model.controlState()
            }
            service.register("open", help: "Open a message from the current list.", arguments: [.init("id", "the message id from state")]) { request in
                try await model.open(messageId: request["id"] as? String ?? "")
                return model.controlState()
            }
            service.register(
                "draft", help: "Prepare a new message or a reply and show it in a compose window; the person reviews and sends it.",
                arguments: [.init("to", "addresses, comma separated"), .init("subject", "the subject"), .init("body", "the text")]
            ) { request in
                try await model.prepareDraft(
                    to: request["to"] as? String ?? "", subject: request["subject"] as? String ?? "",
                    body: request["body"] as? String ?? "", replyTo: request["replyTo"] as? String)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { services.stop() }
    }

    // Closing the last window keeps Hedwig (and its runner) running, like Mail.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
