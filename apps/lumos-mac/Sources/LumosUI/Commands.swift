import BurrowUI
import LumosCore
import SwiftUI

/// The menu bar. J, N, T, K, V and ⌫ are real key equivalents: a text field
/// keeps its own letters, so typing in the search field never triggers them.
public struct LumosCommands: Commands {
    let model: LumosModel

    public init(model: LumosModel) {
        self.model = model
    }

    public var body: some Commands {
        SidebarCommands()
        // ⌘Z undoes typing in a field, and Lumos's last change everywhere else.
        CommandGroup(replacing: .undoRedo) {
            Button("Herstel") {
                if NSApp.keyWindow?.firstResponder is NSText {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else {
                    Task { await model.undo() }
                }
            }
            .keyboardShortcut("z")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Zoek") { model.requestSearchFocus() }.keyboardShortcut("f")
        }
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Ontdekken") { Task { await model.show(.discover) } }.keyboardShortcut("1")
            Button(model.listName) { Task { await model.show(.list) } }.keyboardShortcut("2")
            Button("Bibliotheek") { Task { await model.show(.library) } }.keyboardShortcut("3")
            Divider()
            Button("Alleen films") { Task { await model.showDiscover(.movie) } }.keyboardShortcut("4")
            Button("Alleen series") { Task { await model.showDiscover(.tv) } }.keyboardShortcut("5")
            Divider()
            Button("Verras me") { Task { await model.surprise() } }.keyboardShortcut("v", modifiers: [])
            Button("Vernieuw") { Task { await model.reload() } }.keyboardShortcut("r")
            Button("Terug") { model.back() }
                .keyboardShortcut("[")
                .disabled(!model.inspectorShown)
            Divider()
            Button(model.libraryInspector ? "Verberg inspector" : "Toon inspector") { model.libraryInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.page != .library)
        }
        CommandMenu("Titel") {
            TitleMenuItems(model: model)
        }
    }
}

/// The Titel menu: the same actions as a poster's or a row's context menu.
struct TitleMenuItems: View {
    let model: LumosModel

    var body: some View {
        let target = model.target
        let title = target.flatMap { model.summary($0) }
        let held = title?.availability.held == true
        Button(title?.onList == true ? "Haal van \(model.listName.lowercased())" : "Zet op \(model.listName.lowercased())") {
            Task { await model.toggleList() }
        }
        .keyboardShortcut("j", modifiers: [])
        .disabled(title == nil)
        Button("Niet nu…") { Task { await model.askNotNow() } }
            .keyboardShortcut("n", modifiers: [])
            .disabled(title == nil)
        Button("Al gezien") { Task { await model.seen() } }
            .disabled(title == nil)
        Divider()
        Button("Speel trailer af") { Task { await model.playTrailer() } }
            .keyboardShortcut("t", modifiers: [])
            .disabled(title == nil)
        Button("Kijk op de tv") { Task { await model.watch() } }
            .keyboardShortcut("k", modifiers: [])
            .disabled(!held || !model.canWatch)
        Button("Kijk hier in Jellyfin") { model.watchHere() }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(model.watchInfo?.web == nil)
        Divider()
        Button("Verwijder van Dobby…") { model.askDelete() }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!model.canDeleteTarget)
    }
}

/// The settings window (⌘,): the connection, taste and what was passed, and
/// the household.
public struct LumosSettingsView: View {
    @Environment(LumosModel.self) private var model
    @State private var household: HouseholdModel?
    let logoutIdentifier: String

    public init(logoutIdentifier: String) {
        self.logoutIdentifier = logoutIdentifier
    }

    public var body: some View {
        TabView {
            Tab("Algemeen", systemImage: "gearshape") { GeneralSettings(logoutIdentifier: logoutIdentifier) }
            Tab("Smaak", systemImage: "slider.horizontal.3") {
                VerdictSettings(
                    kinds: [.moreLikeThis, .lessLikeThis], action: "Verwijder",
                    header: "Meer en minder zoals dit",
                    footer: "Alles begint neutraal. Bijstellingen gelden alleen voor voorstellen, nooit voor zoeken.",
                    empty: ("Nog geen bijstellingen", "Kies op een titelpagina Meer of Minder zoals dit."))
            }
            Tab("Overgeslagen", systemImage: "eye.slash") {
                VerdictSettings(
                    kinds: [.notNow, .seen], action: "Terugzetten",
                    header: "Niet nu en Al gezien",
                    footer: "Terugzetten brengt een titel terug in de voorstellen. Niet nu is geen afkeer, en Al gezien verlaagt de smaak niet.",
                    empty: ("Niets overgeslagen", "Druk N op een titel om hem over te slaan."))
            }
            if let household {
                Tab("Huishouden", systemImage: "house") { HouseholdSettingsView(model: household) }
            }
        }
        .frame(width: 580, height: 500)
        .task { await model.loadVerdicts() }
        .onAppear {
            if household == nil { household = HouseholdModel(api: { [model] in model.api }) }
        }
    }
}

private struct GeneralSettings: View {
    @Environment(LumosModel.self) private var model
    let logoutIdentifier: String

    var body: some View {
        Form {
            Section {
                LabeledContent("Server", value: model.connection?.serverURL.host() ?? "Niet verbonden")
                LabeledContent("Ingelogd als", value: model.canDelete ? "\(model.myName), beheerder" : model.myName)
                LabeledContent("Catalogus", value: model.status?.catalogue ?? "Niet gekoppeld")
                LabeledContent("Kijken", value: model.canWatch ? "Via Jellyfin" : "Niet gekoppeld")
            }
            Section {
                Button("Uitloggen") { model.logout() }
                    .accessibilityIdentifier(logoutIdentifier)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VerdictSettings: View {
    @Environment(LumosModel.self) private var model
    let kinds: [VerdictKind]
    let action: String
    let header: String
    let footer: String
    let empty: (String, String)

    var body: some View {
        let items = model.settingsVerdicts.filter { kinds.contains($0.kind) }
        if items.isEmpty {
            ContentUnavailableView(empty.0, systemImage: kinds.contains(.seen) ? "eye.slash" : "slider.horizontal.3", description: Text(empty.1))
        } else {
            Form {
                Section {
                    ForEach(items) { verdict in
                        LabeledContent {
                            Button(action) { Task { await model.restore(verdict) } }
                        } label: {
                            HStack(spacing: 10) {
                                Artwork(title: verdict.title, style: .poster)
                                    .frame(width: 28, height: 42)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verdict.title.title)
                                    Text(line(verdict)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(header)
                } footer: {
                    Text(footer).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func line(_ verdict: Verdict) -> String {
        let what: String =
            switch verdict.kind {
            case .seen: "Al gezien"
            case .notNow: verdict.reason ?? "Niet nu"
            case .moreLikeThis: "Meer zoals dit"
            case .lessLikeThis: "Minder zoals dit"
            }
        let who = verdict.scope == .shared ? "Samen" : model.myName
        return "\(what) · \(who) · \(verdict.createdAt.formatted(.dateTime.day().month(.abbreviated)))"
    }
}
