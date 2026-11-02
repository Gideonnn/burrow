import BurrowUI
import HedwigCore
import SwiftUI

struct MessageListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedMessageId) {
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
                // Above the list rather than in it: a list row keeps its first height,
                // and the answer arrives seconds after the results.
                if model.isSearching {
                    SearchHeader(place: placeTitle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
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
        if model.isSearching {
            let total = max(model.searchTotal, model.messages.count)
            return total == 1 ? "1 resultaat" : "\(total.formatted()) resultaten"
        }
        if let filter = model.filterDescription { return filter }
        let (total, unread) = model.placeCount
        let count = MailFormat().count(total: total, unread: unread)
        return openReviews.isEmpty ? count : "\(count), \(openReviews.count) te controleren"
    }
}

/// Above search results: where it looks, what the bot made of the question as chips,
/// its answer, and lenses to narrow by.
private struct SearchHeader: View {
    @Environment(AppModel.self) private var model
    let place: String

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.placeScope != .everywhere {
                    Picker("Zoek in", selection: $model.searchEverywhere) {
                        Text(place).tag(false)
                        Text("Overal").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer(minLength: 0)
                Menu {
                    Picker("Volgorde", selection: $model.searchSort) {
                        Text("Beste treffers eerst").tag(SearchSort.best)
                        Text("Nieuwste eerst").tag(SearchSort.newest)
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Toon ook codes", isOn: $model.searchIncludesLow)
                } label: {
                    Text(model.searchSort == .best ? "Beste" : "Nieuwste")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Volgorde, en of inlogcodes en wachtwoordherstel meedoen")
            }
            AIRow()
            if let answer = model.searchAnswer { AnswerCard(answer: answer) }
            let lenses = model.searchLenses
            if !lenses.isEmpty {
                ChipRow {
                    ForEach(lenses) { lens in
                        Button { model.addSearchToken(lens.token) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: lens.token.systemImage).imageScale(.small)
                                Text(lens.token.label).lineLimit(1)
                                Text("\(lens.count)").foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(.separator))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Verfijn tot \(lens.token.label)")
                    }
                }
            }
        }
    }
}

/// One line of chips that scrolls sideways. A wrapping layout here made the column's
/// minimum height that of every chip on its own line, which pushed the window's
/// content up under the toolbar.
private struct ChipRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) { content }
        }
        .scrollClipDisabled()
    }
}

/// What the bot is doing, or what it searched for as chips that can be dropped.
private struct AIRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.aiSearching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Kreacher bedenkt waar hij moet zoeken…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if !model.planTokens.isEmpty || model.searchExplanation != nil {
            VStack(alignment: .leading, spacing: 5) {
                ChipRow {
                    Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                    ForEach(model.planTokens) { token in
                        Button { model.removePlanToken(token) } label: {
                            HStack(spacing: 3) {
                                Image(systemName: token.systemImage).imageScale(.small)
                                Text(token.label).lineLimit(1)
                                Image(systemName: "xmark").imageScale(.small).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Zoek zonder \(token.label)")
                    }
                }
                if model.searchRanking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Kreacher leest de beste resultaten…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } else {
            Label(model.searchLoose ? "Geen mail met al deze woorden; dit lijkt er het meest op. ↩ zoekt op betekenis." : "↩ zoekt op betekenis of beantwoordt je vraag", systemImage: "sparkles")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// The bot's answer to the question, with the mail it comes from one click away.
private struct AnswerCard: View {
    @Environment(AppModel.self) private var model
    let answer: SearchAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(answer.text)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ForEach(sources, id: \.id) { source in
                Button { model.selectedMessageId = source.id } label: {
                    Label("\(source.from.display) · \(shortDate(source.receivedAt))", systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
    }

    private var sources: [MessageSummary] {
        answer.messageIds.compactMap { id in model.messages.first { $0.id == id } }
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
                if let hit = message.hit, hit.field == "body" {
                    Text(hit.marked)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(message.facts?.summary ?? message.snippet.split(whereSeparator: \.isNewline).joined(separator: " "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
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
