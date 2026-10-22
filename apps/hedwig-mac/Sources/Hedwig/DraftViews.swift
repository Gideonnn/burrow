import HedwigCore
import SwiftUI

/// Drafts prepared by bots or outside agents (through MCP); a person reviews
/// and sends them.
struct DraftListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedDraftId) {
            ForEach(drafts) { draft in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(Address.format(draft.to)).font(.headline).lineLimit(1)
                        Spacer()
                        Text(shortDate(draft.createdAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(draft.subject).font(.subheadline).lineLimit(1)
                    Label("Klaargezet door \(draft.createdBy)", systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .padding(.vertical, 4)
                .tag(draft.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if drafts.isEmpty { ContentUnavailableView("Geen concepten", systemImage: "doc") }
        }
        .navigationTitle("Concepten")
        .navigationSubtitle(model.currentMailboxId.flatMap(model.mailbox).map(mailboxTitle) ?? "")
        .onChange(of: model.selectedDraftId, initial: true) { DraftSelection.shared.id = model.selectedDraftId }
    }

    private var drafts: [Draft] {
        guard case .drafts(let id) = model.selection else { return [] }
        return model.drafts(in: id)
    }
}

@Observable
final class DraftSelection {
    @MainActor static let shared = DraftSelection()
    var id: String?
}

struct DraftDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    private let selection = DraftSelection.shared

    var body: some View {
        if let draft = model.drafts.first(where: { $0.id == selection.id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(draft.subject).font(.title2.weight(.semibold))
                    Text("Aan: \(Address.format(draft.to))").foregroundStyle(.secondary)
                    Text(draft.body).textSelection(.enabled)
                    HStack {
                        Button("Openen om te versturen") { openWindow(value: model.compose(from: draft)) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.me?.can(.send) != true)
                        Button("Weggooien") { Task { await model.discard(draft) } }
                    }
                    .padding(.top, 8)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Geen concept geselecteerd", systemImage: "doc")
        }
    }
}
