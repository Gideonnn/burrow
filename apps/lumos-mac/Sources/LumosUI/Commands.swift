import BurrowUI
import LumosCore
import SwiftUI

/// The menu bar both faces share: undo, the pages and search.
public struct LumosCommands: Commands {
    let model: LumosModel

    public init(model: LumosModel) {
        self.model = model
    }

    public var body: some Commands {
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

/// The settings window: the household, and the connection with log out.
public struct LumosSettingsView: View {
    @Environment(LumosModel.self) private var model
    @State private var household: HouseholdModel?
    let logoutIdentifier: String

    public init(logoutIdentifier: String) {
        self.logoutIdentifier = logoutIdentifier
    }

    public var body: some View {
        TabView {
            if let household {
                HouseholdSettingsView(model: household).tabItem { Label("Huishouden", systemImage: "house") }
            }
            Form {
                LabeledContent("Server", value: model.connection?.serverURL.host() ?? "")
                LabeledContent("Catalogus", value: model.status?.catalogue ?? "Niet gekoppeld")
                Button("Uitloggen") { model.logout() }
                    .accessibilityIdentifier(logoutIdentifier)
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
