import HedwigCore
import SwiftUI

struct MessageListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedMessageId) {
            if model.isSearching { SearchHeader() }
            ForEach(model.messages) { message in
                MessageRow(message: message, showMailbox: model.isSearching || !isInbox)
                    .tag(message.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.isSearching {
                if model.messages.isEmpty && !model.aiSearching { ContentUnavailableView.search(text: model.searchText) }
            } else if model.messages.isEmpty && !model.isLoading {
                ContentUnavailableView("Geen berichten", systemImage: "tray")
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .refreshable { await model.refresh() }
    }

    private var isInbox: Bool {
        if case .inbox = model.selection { return true }
        return false
    }

    private var title: String {
        if model.isSearching { return "Zoeken in alle mailboxen" }
        return switch model.selection {
        case .inbox(let id): model.mailbox(id).map(mailboxTitle) ?? "Inbox"
        case .role(let role): "\(roleTitle(role)) · alle inboxen"
        case .folder(.sent): "Verstuurd"
        case .folder(.archive): "Archief"
        case .folder(.spam): "Spam"
        default: "Hedwig"
        }
    }

    private var subtitle: String {
        if model.isSearching { return model.messages.count == 1 ? "1 resultaat" : "\(model.messages.count) resultaten" }
        let unread = model.messages.filter(\.unread).count
        let count = unread > 0 ? "\(model.messages.count) berichten, \(unread) ongelezen" : "\(model.messages.count) berichten"
        return count
    }
}

/// Above search results: what the bot searched for, or how to ask it.
private struct SearchHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.from.display)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if message.hasAttachments {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(shortDate(message.receivedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.subject).font(.subheadline).lineLimit(1)
                Text(message.snippet.split(whereSeparator: \.isNewline).joined(separator: " "))
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

func shortDate(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if calendar.isDateInYesterday(date) { return "Gisteren" }
    if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(date: .numeric, time: .omitted)
}
