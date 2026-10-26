import BurrowUI
import HogsmeadeCore
import HogsmeadeUI
import SwiftUI

@main
struct HogsmeadeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Hogsmeade", id: "main") {
            RootView()
                .environment(delegate.model)
                .environment(delegate.services.updater)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1200, height: 780)
        .commands { HogsmeadeCommands(model: delegate.model) }

        Settings {
            HogsmeadeSettingsView(logoutIdentifier: "hogsmeade.approve.logout")
                .environment(delegate.model)
                .frame(width: 600, height: 520)
        }
    }
}

struct RootView: View {
    @Environment(OutingsModel.self) private var model

    var body: some View {
        Group {
            if model.connection == nil {
                LoginView(appName: "Hogsmeade", app: "hogsmeade", accent: BurrowColor.hogsmeade) { url, token in
                    try await model.connect(serverURL: url, token: token)
                }
            } else {
                MainView()
            }
        }
        .tint(BurrowColor.hogsmeade)
        .errorAlert(Binding(get: { model.error }, set: { model.error = $0 }))
        .keepsWindowOnScreen()
    }
}

/// Owns the model and starts it at launch, like Lumos and Hedwig.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = OutingsModel(
        store: ConnectionStore(app: "hogsmeade"),
        cacheDirectory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hogsmeade/Cache", isDirectory: true))
    @MainActor lazy var services: AppServices = {
        let model = model
        return AppServices(app: "hogsmeade", appName: "Hogsmeade", api: { model.api })
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
