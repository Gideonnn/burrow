import BurrowUI
import PensieveCore
import SwiftUI

@main
struct PensieveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Pensieve", id: "main") {
            RootView()
                .environment(delegate.model)
                .environment(delegate.recorder)
                .environment(delegate.services.updater)
                .frame(minWidth: 980, minHeight: 600)
        }
        .commands { PensieveCommands(model: delegate.model, recorder: delegate.recorder) }

        Settings {
            SettingsView()
                .environment(delegate.model)
                .frame(width: 620, height: 560)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(delegate.model)
                .environment(delegate.recorder)
        } label: {
            if delegate.recorder.isRecording {
                Label(clock(delegate.recorder.elapsed), systemImage: "record.circle.fill")
            } else {
                Label("Pensieve", systemImage: "waveform")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @Environment(PensieveModel.self) private var model

    var body: some View {
        Group {
            if model.connection == nil {
                LoginView(appName: "Pensieve", app: "pensieve", accent: BurrowColor.pensieve) { url, token in
                    try await model.connect(serverURL: url, token: token)
                }
            } else {
                MainView()
            }
        }
        .tint(BurrowColor.pensieve)
        .errorAlert(Binding(get: { model.error }, set: { model.error = $0 }))
        .keepsWindowOnScreen()
    }
}

struct PensieveCommands: Commands {
    let model: PensieveModel
    let recorder: RecorderController

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Nieuwe opname") { NewRecordingRequest.shared.open = true }
                .keyboardShortcut("n")
                .disabled(recorder.isRecording || model.connection == nil)
            Button("Stop opname") { Task { await recorder.stop() } }
                .keyboardShortcut(".")
                .disabled(!recorder.isRecording)
            Divider()
            Button("Importeer RecHoarder-opnames…") { Task { await importRecHoarder(model) } }
                .disabled(model.connection == nil)
            Button("Kopieer naar iCloud Drive") { Task { await model.mirrorNow() } }
                .disabled(model.connection == nil || !model.mirrorEnabled)
        }
        CommandMenu("Opname") {
            Button("Vernieuw") { Task { await model.reload() } }
                .keyboardShortcut("r")
        }
    }
}

/// The sheet that asks for a title opens from menus, the toolbar and the
/// menu bar alike.
@MainActor
@Observable
final class NewRecordingRequest {
    static let shared = NewRecordingRequest()
    var open = false
}

@MainActor
func importRecHoarder(_ model: PensieveModel) async {
    let (queued, waiting) = await model.importRecHoarder()
    let alert = NSAlert()
    alert.messageText = queued == 0 && waiting == 0 ? "Niets nieuws in iCloud Drive › Meetings" : "RecHoarder-opnames"
    alert.informativeText = [
        queued > 0 ? "\(queued) opname\(queued == 1 ? "" : "s") gaat naar Dobby, met de transcripten en notulen die er al waren." : nil,
        waiting > 0 ? "\(waiting) staat nog alleen in iCloud; die worden nu gedownload. Importeer straks nog eens." : nil,
    ].compactMap { $0 }.joined(separator: "\n\n")
    alert.runModal()
}

/// Owns the model and starts it at launch, so uploads, the iCloud copy and
/// the menu bar keep going with every window closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = PensieveModel()
    @MainActor lazy var recorder = RecorderController(model: model)
    @MainActor lazy var dictation = DictationController(model: model)
    @MainActor lazy var services: AppServices = {
        let model = model
        return AppServices(app: "pensieve", appName: "Pensieve", api: { model.api })
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            if model.connection != nil {
                await model.start()
                await model.mirrorNow()
            }
        }
        Task { @MainActor in startControl() }
        Task { @MainActor in services.startUpdates() }
        // Uploads that failed earlier get another try every ten minutes.
        Task { @MainActor [model] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                await model.sendPending()
                await model.mirrorNow()
            }
        }
    }

    @MainActor func restart() {
        services.restart { [model] in model.error = $0 }
    }

    @MainActor private func startControl() {
        let model = model
        let recorder = recorder
        services.startControl(
            state: { controlState(model, recorder) },
            busy: { recorder.isRecording ? "a recording is running" : nil },
            onError: { model.error = $0 }
        ) { service in registerCommands(service, model: model, recorder: recorder) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { services.stop() }
    }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.isRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Er loopt nog een opname"
        alert.informativeText = "Stop de opname eerst, of stop en sluit Pensieve: de opname wordt dan bewaard en later geüpload."
        alert.addButton(withTitle: "Ga door met opnemen")
        alert.addButton(withTitle: "Stop en sluit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            await recorder.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // Closing the window keeps Pensieve in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
