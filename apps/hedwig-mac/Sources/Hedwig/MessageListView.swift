import BurrowUI
import HedwigCore
import SwiftUI

struct MessageListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedMessageId) {
            if model.isSearching { SearchHeader(place: placeTitle) }
            ForEach(model.messages) { message in
                VStack(alignment: .leading, spacing: 6) {
                    MessageRow(message: message, showMailbox: model.isSearching && model.searchScope.mailboxId == nil)
                    if !model.isSearching, let entry = model.review(for: message.id) { ReviewLine(entry: entry) }
                }
                .tag(message.id)
            }
        }
        .listStyle(.inset)
        .pullToRefresh { await model.refresh() }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(model.mailboxesToReconnect) { box in
                    ReconnectNotice(mailbox: box)
                    Divider()
                }
            }
        }
        .overlay {
            if model.isSearching {
                if model.messages.isEmpty && !model.aiSearching { ContentUnavailableView.search(text: model.searchText) }
            } else if model.messages.isEmpty && !model.isLoading {
                if model.isFiltering {
                    ContentUnavailableView("Geen berichten", systemImage: "line.3.horizontal.decrease", description: Text("Niets past bij het filter."))
                } else {
                    ContentUnavailableView("Geen berichten", systemImage: "tray")
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            if !model.isSearching, !openReviews.isEmpty {
                ToolbarItem {
                    Button("Alles klopt") { Task { await model.confirmReviews() } }
                        .disabled(model.me?.can(.organize) != true)
                }
            }
        }
    }

    private var openReviews: [FilteredEntry] {
        guard case .folder(let folder, let id) = model.selection else { return [] }
        return model.reviews(in: folder, mailboxId: id)
    }

    private var title: String {
        if model.isSearching {
            return model.searchEverywhere || model.placeScope == .everywhere ? "Zoeken in alle mailboxen" : "Zoeken in \(placeTitle)"
        }
        return placeTitle
    }

    private var placeTitle: String {
        switch model.selection {
        case .inbox(let id): model.mailbox(id).map(mailboxTitle) ?? "Inbox"
        case .folder(let folder, let id): "\(folderTitle(folder)) · \(model.mailbox(id).map(mailboxTitle) ?? "")"
        default: "Hedwig"
        }
    }

    private var subtitle: String {
        if model.isSearching { return model.messages.count == 1 ? "1 resultaat" : "\(model.messages.count) resultaten" }
        if let filter = model.filterDescription { return filter }
        let (total, unread) = model.placeCount
        let count = MailFormat().count(total: total, unread: unread)
        return openReviews.isEmpty ? count : "\(count), \(openReviews.count) te controleren"
    }
}

/// Above search results: where it looks, and what the bot searched for or how to ask it.
private struct SearchHeader: View {
    @Environment(AppModel.self) private var model
    let place: String

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if model.placeScope != .everywhere {
                    Picker("Zoek in", selection: $model.searchEverywhere) {
                        Text(place).tag(false)
                        Text("Alle mailboxen").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Toggle("Toon ook codes", isOn: $model.searchIncludesLow)
                    .help("Inlogcodes, wachtwoordherstel en andere mail met lage prioriteit")
                    .fixedSize()
            }
            HStack(spacing: 6) {
                if model.aiSearching {
                    ProgressView().controlSize(.small)
                    Text("Hedwig zoekt op betekenis…")
                } else if let explanation = model.searchExplanation {
                    Image(systemName: "sparkles")
                    Text(explanation)
                } else {
                    Image(systemName: "sparkles")
                    Text("Druk op ↩ om op betekenis te zoeken")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .selectionDisabled()
    }
}

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: MessageSummary
    var showMailbox = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.unread ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            // Mail's list: the sender at 13 pt semibold, the rest in its 11 pt list font.
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.from.display)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Group {
                        if message.facts?.sensitive == true {
                            Image(systemName: "lock.fill")
                                .help("Bevat gevoelige gegevens; gaat nooit naar een cloud-AI")
                        }
                        if message.hasAttachments { Image(systemName: "paperclip") }
                        Text(shortDate(message.receivedAt))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Text(message.subject).font(.subheadline).lineLimit(1)
                Text(message.facts?.summary ?? message.snippet.split(whereSeparator: \.isNewline).joined(separator: " "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if message.flagged || !message.labels.isEmpty || showMailbox {
                    HStack(spacing: 5) {
                        if message.flagged { Tag(text: "Antwoord nodig", color: .orange) }
                        ForEach(message.labels, id: \.self) { Tag(text: $0, color: .secondary) }
                        if showMailbox, let box = model.mailbox(message.mailboxId) {
                            Tag(text: box.address, color: .secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .overlay(Capsule().strokeBorder(color.opacity(0.5)))
    }
}

func shortDate(_ date: Date) -> String { MailFormat().listDate(date) }
