import BurrowUI
import PensieveCapture
import PensieveCore
import PensieveMedia
import SwiftUI

struct SettingsView: View {
    @Environment(PensieveModel.self) private var model
    @State private var household: HouseholdModel?

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Algemeen", systemImage: "slider.horizontal.3") }
            DeviceSettings().tabItem { Label("Apparaten", systemImage: "mic") }
            LabelSettings().tabItem { Label("Labels", systemImage: "tag") }
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

/// What happens after a recording, the files, and the shortcuts. Everything
/// has a good default; nobody needs this page to begin.
struct GeneralSettings: View {
    @Environment(PensieveModel.self) private var model
    @Environment(RecorderController.self) private var recorder
    @Environment(DictationController.self) private var dictation
    @AppStorage(MacSettings.transcribeKey(.call)) private var calls = true
    @AppStorage(MacSettings.transcribeKey(.video)) private var videos = false
    @AppStorage(MacSettings.transcribeKey(.screen)) private var screens = false
    @AppStorage(MacSettings.dictation) private var dictationOn = true

    var body: some View {
        @Bindable var recorder = recorder
        Form {
            Section("Automatisch na de opname") {
                Toggle(isOn: $calls) { Explained(RecordingKind.call.plural, "Transcript en samenvatting", kind: .call) }
                Toggle(isOn: $dictationOn) {
                    Explained(RecordingKind.dictation.plural, dictation.problem ?? "Houd ⌥ Spatie ingedrukt; de tekst komt waar de cursor staat", kind: .dictation)
                }
                .onChange(of: dictationOn) { if dictationOn { dictation.enable() } else { dictation.disable() } }
                Toggle(isOn: $videos) { Explained(RecordingKind.video.plural, videos ? "Transcript en samenvatting" : "Transcript pas als je op de knop drukt", kind: .video) }
                Toggle(isOn: $screens) { Explained(RecordingKind.screen.plural, screens ? "Transcript en stappen" : "Transcript pas als je op de knop drukt", kind: .screen) }
            }
            Section("Bestanden") {
                Picker(selection: $recorder.format) {
                    Text("Klein · 720p").tag(RecordingFormat.small)
                    Text("Normaal · 1080p").tag(RecordingFormat.normal)
                    Text("Hoog").tag(RecordingFormat.high)
                } label: {
                    Explained("Formaat van video", "Het bestand dat je deelt en bewaart")
                }
                LabeledContent {
                    Text("Altijd").foregroundStyle(.secondary)
                } label: {
                    Explained("Geluid ernaast", "Een audio.m4a in elke map, ook bij video, zodat opnieuw transcriberen kan zonder de video")
                }
                LabeledContent {
                    Button("Toon in Finder") { NSWorkspace.shared.open(model.mirror.root) }
                } label: {
                    Explained("Map", "iCloud Drive › Pensieve: één map per opname, namen in kleine letters, labels als Finder-tags")
                }
                if let last = model.lastMirror {
                    LabeledContent("Laatst bijgewerkt", value: last.formatted(date: .omitted, time: .shortened))
                }
            }
            Section("Sneltoetsen") {
                LabeledContent("Nieuwe opname") { Text("⌘N  in de app").foregroundStyle(.secondary) }
                LabeledContent("Gesprek, video, scherm") { Text("⌘1, ⌘2, ⌘3").foregroundStyle(.secondary) }
                LabeledContent("Markeer moment") { Text("⇧⌘M").foregroundStyle(.secondary) }
                LabeledContent("Dicteren (ingedrukt houden)") { Text("⌥ Spatie  overal").foregroundStyle(.secondary) }
                LabeledContent("Stop") { Text("⌘.").foregroundStyle(.secondary) }
            }
            Section("Ouder werk") {
                LabeledContent {
                    Button("Importeer…") { Task { await importRecHoarder(model) } }
                } label: {
                    Explained("RecHoarder", "Haalt iCloud Drive › Meetings eenmalig naar Dobby; al \(model.importedFolders.count) geïmporteerd")
                }
                LabeledContent {
                    if !model.pending.isEmpty { Button("Probeer nu") { Task { await model.sendPending() } } }
                } label: {
                    Explained("Wacht op upload", model.pending.isEmpty ? "Niets" : model.pending.map(\.title).joined(separator: ", "))
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A setting's name with a line under it, as System Settings shows them.
private struct Explained: View {
    let title: String
    let detail: String
    var kind: RecordingKind?

    init(_ title: String, _ detail: String, kind: RecordingKind? = nil) {
        self.title = title
        self.detail = detail
        self.kind = kind
    }

    var body: some View {
        HStack(spacing: 10) {
            if let kind { Image(systemName: kind.symbol).foregroundStyle(.tint).frame(width: 20) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DeviceSettings: View {
    @Environment(RecorderController.self) private var recorder
    @State private var cameras: [Camera] = []

    var body: some View {
        @Bindable var recorder = recorder
        Form {
            Section {
                Picker("Microfoon", selection: $recorder.microphone) {
                    ForEach(recorder.microphones, id: \.uid) { Text($0.name).tag(Optional($0)) }
                }
                Picker("Camera", selection: $recorder.camera) {
                    Text("Standaard").tag(String?.none)
                    ForEach(cameras, id: \.uid) { Text($0.name).tag(Optional($0.uid)) }
                }
                Toggle(isOn: $recorder.screenWithMicrophone) {
                    Explained("Microfoon bij scherm opnemen", "Anders alleen wat de Mac afspeelt")
                }
            } footer: {
                Text("Een gesprek neemt je microfoon op en alles wat de Mac afspeelt, dus ook de andere kant van een Zoom- of Teams-gesprek. Vraag de anderen of het goed is dat je opneemt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            recorder.refreshMicrophones()
            cameras = PensieveCapture.cameras()
        }
    }
}

/// The person's own labels: free text, no colours.
struct LabelSettings: View {
    @Environment(PensieveModel.self) private var model
    @State private var selection: String?
    @State private var renaming: RecordingLabel?
    @State private var name = ""
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(model.labels) { label in
                        LabeledContent(label.name) {
                            Text(label.count == 1 ? "1 opname" : "\(label.count) opnames").foregroundStyle(.secondary)
                        }
                        .tag(label.id)
                        .contextMenu {
                            Button("Wijzig naam…") { rename(label) }
                            Button("Verwijder", role: .destructive) { Task { await model.deleteLabel(label.id) } }
                        }
                    }
                }
                .frame(minHeight: 220)
                .overlay { if model.labels.isEmpty { Text("Nog geen labels").foregroundStyle(.secondary) } }
            } footer: {
                HStack {
                    Button { name = ""; adding = true } label: { Image(systemName: "plus") }
                    Button { if let label = chosen { Task { await model.deleteLabel(label.id) } } } label: { Image(systemName: "minus") }
                        .disabled(chosen == nil)
                    Button("Wijzig naam…") { if let label = chosen { rename(label) } }
                        .disabled(chosen == nil)
                    Spacer()
                    Text("Verwijderen haalt het label van de opnames; de opnames blijven.").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .alert("Nieuw label", isPresented: $adding) {
            TextField("Naam", text: $name)
            Button("Voeg toe") { Task { await model.addLabel(name) } }
            Button("Annuleer", role: .cancel) {}
        }
        .alert("Naam van het label", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Naam", text: $name)
            Button("Bewaar") { if let id = renaming?.id { Task { await model.renameLabel(id, to: name) } } }
            Button("Annuleer", role: .cancel) {}
        }
    }

    private var chosen: RecordingLabel? { model.labels.first { $0.id == selection } }

    private func rename(_ label: RecordingLabel) {
        name = label.name
        renaming = label
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
