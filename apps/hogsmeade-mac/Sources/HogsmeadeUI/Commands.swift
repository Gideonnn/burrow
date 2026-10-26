import BurrowUI
import HogsmeadeCore
import SwiftUI

/// The menu bar both faces share: new, the pages, search and refresh.
public struct HogsmeadeCommands: Commands {
    let model: OutingsModel

    public init(model: OutingsModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nieuw uitje") { model.newRequest += 1 }.keyboardShortcut("n")
        }
        CommandMenu("Uitjes") {
            Button("Binnenkort") { model.page = .upcoming; model.close() }.keyboardShortcut("1")
            Button("Geweest") { model.page = .past; model.close() }.keyboardShortcut("2")
            Divider()
            Button("Zoek") { model.searchFocusRequest += 1 }.keyboardShortcut("f")
            Button("Vernieuw") { Task { await model.refresh() } }.keyboardShortcut("r")
        }
    }
}

/// The settings window: the household, and the connection with log out.
public struct HogsmeadeSettingsView: View {
    @Environment(OutingsModel.self) private var model
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
                LabeledContent("Ingelogd als", value: model.me?.person.name ?? "")
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
