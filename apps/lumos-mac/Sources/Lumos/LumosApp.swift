import BurrowUI
import LumosCore
import SwiftUI

@main
struct LumosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Lumos", id: "main") {
            RootView()
                .environment(delegate.model)
                .environment(delegate.services.updater)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1360, height: 860)
        .commands { LumosCommands(model: delegate.model) }

        Settings {
            SettingsView()
                .environment(delegate.model)
                .tint(BurrowColor.lumos)
                .frame(width: 600, height: 520)
        }
    }
}

struct RootView: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        Group {
            if model.connection == nil {
                LoginView(appName: "Lumos", app: "lumos", accent: BurrowColor.lumos) { url, token in
                    try await model.connect(serverURL: url, token: token)
                }
            } else {
                MainView()
            }
        }
        .tint(BurrowColor.lumos)
        .errorAlert(Binding(get: { model.error }, set: { model.error = $0 }))
        .keepsWindowOnScreen()
    }
}

struct LumosCommands: Commands {
    let model: LumosModel

    var body: some Commands {
        // ⌘Z undoes typing in a field, and Lumos's last change everywhere else.
        CommandGroup(replacing: .undoRedo) {
            Button("Ongedaan maken") {
                if NSApp.keyWindow?.firstResponder is NSText {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else {
                    Task { await model.undo() }
                }
            }
            .keyboardShortcut("z")
        }
        CommandMenu("Kijken") {
            Button("Ontdekken") { Task { await model.show(.discover) } }.keyboardShortcut("1")
            Button("Lijst") { Task { await model.show(.list) } }.keyboardShortcut("2")
            Button("Smaak") { Task { await model.show(.taste) } }.keyboardShortcut("3")
            Divider()
            Button("Zoek") { model.requestSearchFocus() }.keyboardShortcut("f")
            Button("Vernieuw") { Task { await model.reload() } }.keyboardShortcut("r")
        }
    }
}

struct SettingsView: View {
    @Environment(LumosModel.self) private var model
    @State private var household: HouseholdModel?

    var body: some View {
        TabView {
            if let household {
                HouseholdSettingsView(model: household).tabItem { Label("Huishouden", systemImage: "house") }
            }
            Form {
                LabeledContent("Server", value: model.connection?.serverURL.host() ?? "")
                LabeledContent("Catalogus", value: model.status?.catalogue ?? "Niet gekoppeld")
                Button("Uitloggen") { model.logout() }
                    .accessibilityIdentifier("lumos.approve.logout")
            }
            .formStyle(.grouped)
            .tabItem { Label("Verbinding", systemImage: "network") }
        }
        .padding(20)
        .onAppear {
            if household == nil { household = HouseholdModel(api: { [model] in model.api }) }
        }
    }
}

/// Owns the model and starts it at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = LumosModel()
    @MainActor lazy var services: AppServices = {
        let model = model
        return AppServices(app: "lumos", appName: "Lumos", api: { model.api })
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

    @MainActor private func startControl() {
        let model = model
        services.startControl(state: { controlState(model) }, onError: { model.error = $0 }) { service in
            registerCommands(service, model: model)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { services.stop() }
    }
}
