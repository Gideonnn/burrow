import BurrowUI
import HedwigCore
import SwiftUI

@main
struct HedwigApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        // One mail window, like Mail's viewer: a second one only mirrored the first.
        Window("Hedwig", id: "main") {
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

        WindowGroup("Bericht", for: OpenMessage.self) { $message in
            if let message {
                MessageWindow(id: message.id)
                    .environment(model)
                    .frame(minWidth: 480, minHeight: 360)
            }
        }
        .defaultSize(width: 720, height: 760)

        Settings {
            SettingsView()
                .environment(model)
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
        .errorAlert(Binding(get: { model.error }, set: { model.error = $0 }))
        .keepsWindowOnScreen()
    }
}

/// The mail window's model while that window is key; nil in a compose window or Settings.
struct MailWindowKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var mailWindow: AppModel? {
        get { self[MailWindowKey.self] }
        set { self[MailWindowKey.self] = newValue }
    }
}

struct HedwigCommands: Commands {
    let model: AppModel
    @FocusedValue(\.mailWindow) private var window
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        // Replacing the group drops the system's New Window, which also wanted ⌘N.
        CommandGroup(replacing: .newItem) {
            Button("Nieuw bericht") { if let d = model.newMessage() { openWindow(value: d) } }
                .keyboardShortcut("n")
                .disabled(model.me == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Zoek") { window?.searchFocusRequest += 1 }
                .keyboardShortcut("f")
                .disabled(window == nil)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            GoToItems(model: window)
            Divider()
            Button(window?.filterOn == true ? "Zet filter uit" : "Filter de lijst") { window?.filterOn.toggle() }
                .keyboardShortcut("l")
                .disabled(window?.placeScope == nil || window?.isSearching == true)
        }
        CommandMenu("Bericht") {
            MessageMenuItems(model: window, openWindow: openWindow)
        }
    }
}

/// ⌘1 to ⌘9 open the mailboxes in sidebar order, like Mail's favourites.
private struct GoToItems: View {
    let model: AppModel?

    var body: some View {
        let boxes = (model?.mailboxGroups ?? []).flatMap(\.mailboxes)
        ForEach(Array(boxes.prefix(9).enumerated()), id: \.element.id) { index, box in
            Button("Ga naar \(mailboxTitle(box))") { model?.selection = .inbox(mailboxId: box.id) }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
        }
        Button("Ga naar Taken") { model?.selection = .tasks }
            .disabled(model == nil)
        Button("Ga naar Gedeeld") { model?.selection = .shared }
            .disabled(model == nil)
    }
}

/// The Bericht menu; every item is grey when the mail window is not key or
/// nothing in it can be acted on.
private struct MessageMenuItems: View {
    let model: AppModel?
    let openWindow: OpenWindowAction

    var body: some View {
        let canReply = model?.showsMail == true && model?.canReply == true
        let canOrganize = model?.showsMail == true && model?.canOrganizeSelection == true
        let ids = model?.selectedIds ?? []
        let list = model?.summaries(ids) ?? []
        Button("Beantwoord") { if let d = model?.reply() { openWindow(value: d) } }
            .keyboardShortcut("r")
            .disabled(!canReply)
        Button("Allen beantwoorden") { if let d = model?.reply(all: true) { openWindow(value: d) } }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!canReply)
        Button("Stuur door") { if let d = model?.forward() { openWindow(value: d) } }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!canReply)
        Divider()
        Button("Archiveer") { Task { await model?.perform([.archive]) } }
            .keyboardShortcut("a", modifiers: [.command, .control])
            .disabled(!canOrganize || list.allSatisfy { $0.folder == .archive })
        Button("Verwijder") { Task { await model?.perform([.trash]) } }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!canOrganize)
        Button("Markeer als spam") { Task { await model?.perform([.moveToSpam]) } }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(!canOrganize || list.allSatisfy { $0.folder == .spam })
        Divider()
        Button(list.contains(where: \.unread) ? "Markeer als gelezen" : "Markeer als ongelezen") {
            Task { await model?.toggleRead() }
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .disabled(!canOrganize)
        Button(!list.isEmpty && list.allSatisfy(\.flagged) ? "Verwijder vlag" : "Markeer met vlag") {
            Task { await model?.toggleFlag() }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(!canOrganize)
        Divider()
        Button("Vernieuw") { Task { await model?.refresh() } }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model == nil)
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
    @MainActor lazy var notifications = OutingNotifications(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            // The outings page moved to Hogsmeade; the reminders stay here until it has them.
            model.followsOutings = true
            notifications.start()
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
        services.startControl(
            state: { model.controlState() },
            busy: { model.composing > 0 ? "a message is being written" : nil },
            onError: { model.error = $0 }
        ) { service in
            service.register(
                "show", help: "Show a list: inbox, archive, sent, spam or drafts of the open mailbox, each also as <place>:<address>; private, work or school (the inbox of its first mailbox); filtered (Spam or Archief with mail to review) or tasks.",
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
