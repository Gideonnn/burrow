import BurrowUI
import LumosCore
import LumosUI
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
            LumosSettingsView(logoutIdentifier: "lumos.approve.logout")
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

/// Owns the model and starts it at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = LumosModel(
        cacheDirectory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lumos/Cache", isDirectory: true))
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
