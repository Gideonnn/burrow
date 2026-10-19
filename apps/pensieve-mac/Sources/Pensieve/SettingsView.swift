import BurrowUI
import PensieveCore
import SwiftUI

struct SettingsView: View {
    @Environment(PensieveModel.self) private var model
    @State private var household: HouseholdModel?

    var body: some View {
        TabView {
            ArchiveSettings().tabItem { Label("Archief", systemImage: "archivebox") }
            if let household {
                HouseholdSettingsView(model: household).tabItem { Label("Huishouden", systemImage: "house") }
                WorkersView(model: household).tabItem { Label("Workers", systemImage: "person.2.wave.2") }
            }
            ConnectionSettings().tabItem { Label("Verbinding", systemImage: "network") }
        }
        .padding(20)
        .onAppear {
            if household == nil { household = HouseholdModel(api: { [model] in model.api }) }
        }
    }
}

/// The copy in iCloud Drive, the RecHoarder import and the upload queue.
struct ArchiveSettings: View {
    @Environment(PensieveModel.self) private var model

    var body: some View {
        Form {
            Section("iCloud Drive") {
                LabeledContent("Map") {
                    Button("iCloud Drive › Pensieve") { NSWorkspace.shared.open(model.mirror.root) }.buttonStyle(.link)
                }
                Text(model.mirrorEnabled
                    ? "Je eigen en gedeelde opnames komen hier als map met audio, transcript en notulen. Zet dit uit onder Huishouden."
                    : "Staat uit. Zet ‘Kopie in iCloud Drive’ aan onder Huishouden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = model.lastMirror {
                    LabeledContent("Laatst bijgewerkt", value: last.formatted(date: .omitted, time: .shortened))
                }
                Button("Werk nu bij") { Task { await model.mirrorNow() } }.disabled(!model.mirrorEnabled)
            }
            Section("RecHoarder") {
                Text("Haalt de opnames uit iCloud Drive › Meetings eenmalig naar Dobby, met de transcripten en notulen die er al waren. De originelen blijven staan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Al geïmporteerd", value: "\(model.importedFolders.count)")
                Button("Importeer RecHoarder-opnames…") { Task { await importRecHoarder(model) } }
            }
            Section("Wacht op upload") {
                if model.pending.isEmpty { Text("Niets").foregroundStyle(.secondary) }
                ForEach(model.pending) { upload in
                    VStack(alignment: .leading) {
                        Text(upload.title)
                        if let error = upload.lastError { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                if !model.pending.isEmpty { Button("Probeer nu") { Task { await model.sendPending() } } }
            }
        }
        .formStyle(.grouped)
    }
}

struct ConnectionSettings: View {
    @Environment(PensieveModel.self) private var model

    var body: some View {
        Form {
            LabeledContent("Server", value: model.connection?.serverURL.absoluteString ?? "")
            LabeledContent("Ingelogd als", value: model.profile?.person.name ?? "")
            LabeledContent("Apparaat", value: model.profile?.key.name ?? "")
            Button("Uitloggen", role: .destructive) { model.logout() }
                .accessibilityIdentifier("pensieve.approve.logout")
        }
        .formStyle(.grouped)
    }
}
