import HedwigCore
import SwiftUI

/// The "Gefilterd" review: what the bot moved out of the inbox, with its
/// reason, to confirm or restore.
struct FilteredListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedFilteredId) {
            ForEach(model.filtered) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.message.from.display).font(.headline).lineLimit(1)
                        Spacer()
                        Text(shortDate(entry.message.receivedAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(entry.message.subject).font(.subheadline).lineLimit(1)
                    Label(entry.reason, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    HStack {
                        Tag(text: (entry.unsure ? "Twijfel · " : "") + kindName(entry.action.kind), color: entry.unsure ? .orange : .secondary)
                        Spacer()
                        Button("Klopt") { Task { await model.confirm(entry) } }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.green)
                        Button("Terug") { Task { await model.restore(entry) } }
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
                .padding(.vertical, 4)
                .tag(entry.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.filtered.isEmpty {
                ContentUnavailableView(
                    "Alles gecontroleerd", systemImage: "checkmark.shield",
                    description: Text("De agent heeft van je keuzes geleerd."))
            }
        }
        .navigationTitle("Gefilterd")
        .navigationSubtitle(model.filtered.isEmpty ? "" : "\(model.filtered.count) te controleren")
        .toolbar {
            ToolbarItem {
                Button("Alles klopt") { Task { await model.confirmAll() } }
                    .disabled(model.filtered.isEmpty || model.me?.can(.organize) != true)
            }
        }
    }
}

struct FilteredDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let entry = model.filtered.first(where: { $0.id == model.selectedFilteredId }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(entry.message.subject).font(.title2.weight(.semibold))
                    Text("\(entry.message.from.display) <\(entry.message.from.email)>").foregroundStyle(.secondary)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(
                                (entry.unsure ? "Twijfelgeval · " : "") + "Gefilterd als \(kindName(entry.action.kind).lowercased())",
                                systemImage: "checkmark.shield"
                            )
                            .font(.headline)
                            .foregroundStyle(entry.unsure ? .orange : .primary)
                            Text(entry.reason)
                            Label("Op de server: \(entry.serverOps.joined(separator: ", "))", systemImage: "server.rack")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Label("Op je telefoon: niet in de inbox, geen badge", systemImage: "iphone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Klopt") { Task { await model.confirm(entry) } }
                                    .keyboardShortcut(.return, modifiers: [])
                                Button("Terugzetten in de inbox") { Task { await model.restore(entry) } }
                                    .keyboardShortcut("u", modifiers: [])
                            }
                            .disabled(model.me?.can(.organize) != true)
                            .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                    Text(entry.message.snippet).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Niets geselecteerd", systemImage: "checkmark.shield")
        }
    }
}

func kindName(_ kind: String) -> String {
    switch kind {
    case "spam": "Spam"
    case "archive": "Gearchiveerd"
    case "needs-reply": "Antwoord nodig"
    case "label": "Label"
    default: kind
    }
}
