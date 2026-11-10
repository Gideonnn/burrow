import BurrowUI
import HedwigCore
import SwiftUI

struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedMessageIds) {
            ForEach(model.messages) { message in
                VStack(alignment: .leading, spacing: 6) {
                    MessageRow(message: message, showMailbox: model.isSearching && model.searchScope.mailboxId == nil)
                    if !model.isSearching, let entry = model.review(for: message.id) { ReviewLine(entry: entry) }
                }
                .tag(message.id)
                // A message id: the sidebar's mailbox folders take it as a move.
                .draggable(message.id)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            MessageContextMenu(ids: model.messages.map(\.id).filter(ids.contains))
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { openWindow(value: OpenMessage(id: id)) }
        }
        .onDeleteCommand {
            if model.canOrganizeSelection { Task { await model.perform([.trash]) } }
        }
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
                    SearchHeader()
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
            return model.searchEverywhere || model.placeScope == .everywhere ? "Zoeken in alle mailboxen" : "Zoeken in \(model.placeTitle)"
        }
        return model.placeTitle
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

extension AppModel {
    /// The open mailbox or folder by name, for titles and the search scope.
    var placeTitle: String {
        switch selection {
        case .inbox(let id): mailbox(id).map(mailboxTitle) ?? "Inbox"
        case .folder(let folder, let id): "\(folderTitle(folder)) · \(mailbox(id).map(mailboxTitle) ?? "")"
        default: "Hedwig"
        }
    }
}

/// Above search results: the order, what the bot made of the question as chips,
/// its answer, and lenses to narrow by. Where it looks is the search field's scope bar.
private struct SearchHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
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
                            Label {
                                Text("\(lens.token.label) \(Text("\(lens.count)").foregroundStyle(.secondary))").lineLimit(1)
                            } icon: {
                                Image(systemName: lens.token.systemImage)
                            }
                        }
                        .chip()
                        .help("Verfijn tot \(lens.token.label)")
                    }
                }
            }
        }
    }
}

extension View {
    /// A search chip: a small bordered capsule button.
    func chip() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
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
                Text("Kreacher bedenkt waar hij moet zoeken…").lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if !model.planTokens.isEmpty || model.searchExplanation != nil {
            VStack(alignment: .leading, spacing: 5) {
                ChipRow {
                    Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                    ForEach(model.planTokens) { token in
                        Button { model.removePlanToken(token) } label: {
                            Label {
                                Text(token.label).lineLimit(1)
                            } icon: {
                                Image(systemName: token.systemImage)
                            }
                        }
                        .chip()
                        .tint(.accentColor)
                        .accessibilityHint("Zoekt zonder dit")
                        .help("Zoek zonder \(token.label)")
                    }
                }
                if model.searchRanking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Kreacher leest de beste resultaten…").lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } else {
            Label(model.searchLoose ? "Niets met al deze woorden; dit lijkt erop. ↩ zoekt op betekenis." : "↩ zoekt op betekenis", systemImage: "sparkles")
                .lineLimit(2)
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
            // A line limit, not fixedSize: at the width zero SwiftUI asks for the minimum,
            // a fixed-size text is one letter per line and pushes the window's content up.
            Text(answer.text)
                .font(.body.weight(.semibold))
                .lineLimit(4)
                .textSelection(.enabled)
            ForEach(sources, id: \.id) { source in
                Button { model.selectedMessageId = source.id } label: {
                    Label("\(source.from.display) · \(shortDate(source.receivedAt))", systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.link)
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
                .accessibilityLabel(message.unread ? "Ongelezen" : "")
                .accessibilityHidden(!message.unread)
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

/// The list's context menu: the same actions as the Bericht menu, for the
/// clicked messages. Reply and forward take one message.
struct MessageContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let ids: [String]

    var body: some View {
        let list = model.summaries(ids)
        let one = list.count == 1 ? list.first : nil
        let canSend = one != nil && one?.share?.by == nil && model.me?.can(.send) == true
        let canOrganize = model.canOrganize(ids)
        if let one {
            Button("Open in nieuw venster") { openWindow(value: OpenMessage(id: one.id)) }
            Divider()
        }
        Button("Beantwoord") { compose(all: false, forwarding: false) }.disabled(!canSend)
        Button("Allen beantwoorden") { compose(all: true, forwarding: false) }.disabled(!canSend)
        Button("Stuur door") { compose(all: false, forwarding: true) }.disabled(!canSend)
        Divider()
        Button("Archiveer") { Task { await model.move(ids, to: .archive) } }
            .disabled(!model.canMove(ids, to: .archive))
        Button(list.contains(where: \.unread) ? "Markeer als gelezen" : "Markeer als ongelezen") {
            Task { await model.toggleRead(ids) }
        }
        .disabled(!canOrganize)
        Button(!list.isEmpty && list.allSatisfy(\.flagged) ? "Verwijder vlag" : "Markeer met vlag") {
            Task { await model.toggleFlag(ids) }
        }
        .disabled(!canOrganize)
        Menu("Verplaats naar") {
            ForEach([MailFolder.inbox, .archive, .spam], id: \.self) { folder in
                Button(folderTitle(folder)) { Task { await model.move(ids, to: folder) } }
                    .disabled(!model.canMove(ids, to: folder))
            }
        }
        .disabled(!canOrganize)
        Divider()
        Button("Verwijder", role: .destructive) { Task { await model.perform([.trash], on: ids) } }
            .disabled(!canOrganize)
    }

    private func compose(all: Bool, forwarding: Bool) {
        guard let id = ids.first else { return }
        Task {
            if let draft = await model.draft(replyingTo: id, all: all, forwarding: forwarding) { openWindow(value: draft) }
        }
    }
}
