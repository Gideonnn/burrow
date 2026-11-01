import BurrowUI
import HedwigCore
import SwiftUI

/// Gedeeld: what Winky suggests sharing, what others shared with this person,
/// and what this person shared.
struct SharedListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let suggested = model.messages.filter { $0.shareSuggestion != nil }
        let withMe = model.messages.filter { $0.shareSuggestion == nil && $0.share?.by != nil }
        let byMe = model.messages.filter { $0.shareSuggestion == nil && $0.share?.by == nil }
        List(selection: $model.selectedMessageId) {
            section("Winky stelt voor", suggested)
            section("Met mij gedeeld", withMe)
            section("Door mij gedeeld", byMe)
        }
        .listStyle(.inset)
        .pullToRefresh { await model.refresh() }
        .overlay {
            if model.messages.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "Niets gedeeld", systemImage: "person.2",
                    description: Text("Deel een mail vanuit de lezer, dan kan je huisgenoot hem ook openen en vinden."))
            }
        }
        .navigationTitle("Gedeeld")
        .navigationSubtitle(model.messages.count == 1 ? "1 bericht" : "\(model.messages.count) berichten")
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [MessageSummary]) -> some View {
        if !list.isEmpty {
            Section(title) {
                ForEach(list) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        MessageRow(message: message)
                        Label(note(message), systemImage: "person.2")
                            .font(.caption)
                            .foregroundStyle(message.shareSuggestion != nil ? Color.accentColor : .secondary)
                            .padding(.leading, 16)
                    }
                    .tag(message.id)
                }
            }
        }
    }

    private func note(_ message: MessageSummary) -> String {
        if let suggestion = message.shareSuggestion { return "Winky: \(suggestion.reason)" }
        if let owner = message.share?.by { return "Van \(model.personName(owner))" }
        return "Met \(names(message.share?.with ?? []))"
    }

    private func names(_ ids: [String]) -> String { ids.map(model.personName).joined(separator: ", ") }
}

/// Under the reader's header: who shared the mail, Winky's suggestion to share
/// it, or the button that shares it with the household.
struct ShareBar: View {
    @Environment(AppModel.self) private var model
    let message: MessageDetail
    @State private var always = false

    var body: some View {
        if let owner = message.share?.by {
            Label("Gedeeld door \(model.personName(owner))", systemImage: "person.2")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !model.housemates.isEmpty {
            if let suggestion = message.shareSuggestion {
                suggestionBox(suggestion)
            } else {
                shareButton
            }
        }
    }

    private func suggestionBox(_ suggestion: ShareSuggestionNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Winky: \(suggestion.reason), delen met \(model.housematesTitle)?", systemImage: "person.badge.plus")
                .font(.headline)
            HStack {
                Button("Deel") { Task { await model.decideShareSuggestion(share: true, always: always) } }
                Button("Niet") { Task { await model.decideShareSuggestion(share: false, always: always) } }
                Toggle("Altijd van deze afzender", isOn: $always)
                    .toggleStyle(.checkbox)
                    .help("Deel voortaan elke voorgestelde mail van \(message.from.display), of stel er nooit meer een voor")
            }
            .disabled(model.me?.can(.organize) != true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: message.id) { always = false }
    }

    private var shareButton: some View {
        let with = message.share?.with ?? []
        let shared = !with.isEmpty
        return Button { Task { await model.toggleShare() } } label: {
            Label(
                shared ? "Gedeeld met \(with.map(model.personName).joined(separator: ", "))" : "Deel met \(model.housematesTitle)",
                systemImage: shared ? "person.2.fill" : "person.2")
        }
        .controlSize(.small)
        .help(shared ? "Klik om het delen terug te draaien" : "\(model.housematesTitle) kan deze mail dan ook openen en vinden")
        .disabled(model.me?.can(.organize) != true)
    }
}
