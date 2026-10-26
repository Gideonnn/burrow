import BurrowUI
import HogsmeadeCore
import HogsmeadeUI
import SwiftUI

@main
struct HogsmeadeFeestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Hogsmeade Feest", id: "main") {
            RootView()
                .environment(delegate.model)
                .environment(delegate.services.updater)
                .frame(minWidth: 1000, minHeight: 660)
                // The wall is a night and the scrapbook is cream, whatever the Mac's appearance.
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { HogsmeadeCommands(model: delegate.model) }

        Settings {
            HogsmeadeSettingsView(logoutIdentifier: "hogsmeade-feest.approve.logout")
                .environment(delegate.model)
                .tint(BurrowColor.hogsmeade)
                .frame(width: 600, height: 520)
        }
    }
}

struct RootView: View {
    @Environment(OutingsModel.self) private var model

    var body: some View {
        Group {
            if model.connection == nil {
                LoginView(appName: "Hogsmeade Feest", app: "hogsmeade-feest", accent: BurrowColor.hogsmeade) { url, token in
                    try await model.connect(serverURL: url, token: token)
                }
            } else {
                NightView()
            }
        }
        .tint(Palette.lemon)
        .errorAlert(Binding(get: { model.error }, set: { model.error = $0 }))
        .keepsWindowOnScreen()
    }
}

/// Owns the model and starts it at launch; its own login and cache, apart
/// from the native Hogsmeade, so both run side by side.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = OutingsModel(
        store: ConnectionStore(app: "hogsmeade-feest"),
        cacheDirectory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hogsmeade Feest/Cache", isDirectory: true))
    @MainActor lazy var services: AppServices = {
        let model = model
        return AppServices(app: "hogsmeade-feest", appName: "Hogsmeade Feest", api: { model.api })
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
