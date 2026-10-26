import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

@main
struct HogsmeadeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Hogsmeade", id: "main") {
            RootView()
                .environment(delegate.model)
                .environment(delegate.services.updater)
                .frame(minWidth: 1000, minHeight: 640)
                // The wall is a night and the scrapbook is cream, whatever the Mac's appearance.
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        .commands { LumosCommands(model: delegate.model) }

        Settings {
            LumosSettingsView(logoutIdentifier: "hogsmeade.approve.logout")
                .environment(delegate.model)
                .tint(BurrowColor.hogsmeade)
                .frame(width: 600, height: 520)
        }
    }
}

struct RootView: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        Group {
            if model.connection == nil {
                LoginView(appName: "Hogsmeade", app: "hogsmeade", accent: BurrowColor.hogsmeade) { url, token in
                    try await model.connect(serverURL: url, token: token)
                }
            } else {
                WallView()
            }
        }
        .tint(Palette.lemon)
        .errorAlert(Binding(get: { model.error }, set: { model.error = $0 }))
        .keepsWindowOnScreen()
    }
}

/// Owns the model and starts it at launch, like Lumos.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = LumosModel(
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
