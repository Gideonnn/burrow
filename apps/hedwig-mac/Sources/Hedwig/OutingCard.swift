import AppKit
import HedwigCore
import SwiftUI

/// The Evenement card above an order mail: what Hedwig read, one click to keep
/// it, and once kept the checklist and the tickets.
struct OutingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let outing = model.outing {
                saved(outing)
            } else if let suggestion = model.outingSuggestion {
                suggested(suggestion)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private var title: String { model.outing?.title ?? model.outingSuggestion?.title ?? "Evenement" }
    private var kind: String? { model.outing?.kind ?? model.outingSuggestion?.kind }
    private var startsAt: Date? { model.outing?.startsAt ?? model.outingSuggestion?.startsAt }
    private var venue: String? { model.outing?.venue ?? model.outingSuggestion?.venue }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "ticket")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.pink)
                .frame(width: 30, height: 30)
                .background(.pink.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(["Evenement", kind].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(title).font(.headline).lineLimit(1)
            }
            Spacer()
            if let task = model.outing?.openPersonalise, let due = task.dueAt, due.timeIntervalSinceNow < 30 * 86_400 {
                Text("Op naam zetten").font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .foregroundStyle(.orange).background(.orange.opacity(0.15), in: Capsule())
            }
        }
    }

    private var when: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let startsAt {
                Text(startsAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                    .font(.title3.weight(.semibold))
                Text([startsAt.formatted(date: .omitted, time: .shortened), venue, Self.relative(startsAt)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            } else {
                Text("Geen datum gevonden").foregroundStyle(.secondary)
            }
        }
    }

    private func suggested(_ s: OutingSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            when
            HStack(spacing: 8) {
                Button {
                    Task { await model.saveOuting() }
                } label: {
                    Label("Bewaar als evenement", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(model.outingBusy || s.startsAt == nil)
                Text(Self.saveHint(s)).font(.callout).foregroundStyle(.secondary)
            }
            if s.personaliseBy != nil {
                Label("De kaarten moeten op naam vóór \(s.personaliseBy!.formatted(date: .abbreviated, time: .omitted)); Hedwig zet dat op de lijst.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            source(s.confidence == .structured ? "Uit de gegevens in de mail" : "Gelezen uit de mail; controleer de datum")
        }
    }

    private func saved(_ outing: Outing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            when
            VStack(spacing: 0) {
                ForEach(outing.tasks) { task in
                    TaskRow(task: task)
                    if task.id != outing.tasks.last?.id { Divider() }
                }
                Divider()
                ticketsRow(outing)
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            if !outing.tickets.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(outing.tickets.enumerated()), id: \.element.id) { index, ticket in
                        TicketChip(ticket: ticket, number: index + 1)
                    }
                }
            }
            if !outing.aliases.isEmpty {
                HStack(spacing: 4) {
                    Text("Vind je terug als").font(.caption).foregroundStyle(.secondary)
                    ForEach(outing.aliases.prefix(6), id: \.self) { alias in
                        Text(alias).font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(.separator))
                    }
                }
            }
            source("Gedeeld evenement · toegevoegd door \(outing.createdBy.name)\(outing.vendor.map { " · verkocht door \($0)" } ?? "")")
        }
    }

    private func ticketsRow(_ outing: Outing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: outing.tickets.isEmpty ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(outing.tickets.isEmpty ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(outing.tickets.isEmpty ? "Geen kaarten bewaard" : "\(outing.tickets.count) \(outing.tickets.count == 1 ? "kaart" : "kaarten") bewaard")
                Text(outing.tickets.isEmpty ? "Voeg ze toe onder Evenementen: pdf, Wallet-pas of screenshot." : "Ook op de Mac van de ander, nooit bij een cloud-AI.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func source(_ text: String) -> some View {
        Label(text, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
    }

    private static func saveHint(_ s: OutingSuggestion) -> String {
        let tickets = s.tickets.count
        let base = "Gedeeld, met deze mail erbij"
        return tickets == 0 ? base : "\(base) en \(tickets) \(tickets == 1 ? "kaart" : "kaarten")"
    }

    static func relative(_ date: Date) -> String? {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<0: return "geweest"
        case 0: return "vandaag"
        case 1: return "morgen"
        case 2...60: return "over \(days) dagen"
        default: return "over \(Int((Double(days) / 30.4).rounded())) maanden"
        }
    }
}

private struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: OutingTask

    var body: some View {
        let late = !task.done && (task.dueAt.map { $0.timeIntervalSinceNow < 30 * 86_400 } ?? false)
        HStack(spacing: 8) {
            Button {
                Task { await model.setOutingTask(task, done: !task.done) }
            } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : late ? "exclamationmark.circle.fill" : "circle")
                    .foregroundStyle(task.done ? Color.green : late ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.done ? "Niet gedaan" : "Gedaan")
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).strikethrough(task.done, color: .secondary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(late ? Color.orange : Color.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(late ? Color.orange.opacity(0.08) : .clear)
    }

    private var detail: String? {
        if let by = task.doneBy, let at = task.doneAt {
            return "\(by.name), \(at.formatted(date: .abbreviated, time: .omitted))"
        }
        if task.kind == .calendar { return "Zet het zelf in Wij tot de agenda gekoppeld is" }
        guard let due = task.dueAt else { return task.assignee.map { "Door \($0.name)" } }
        let left = OutingCard.relative(due).map { " · \($0)" } ?? ""
        return "vóór \(due.formatted(date: .abbreviated, time: .omitted))\(left)"
    }
}

private struct TicketChip: View {
    @Environment(AppModel.self) private var model
    let ticket: OutingTicket
    let number: Int

    var body: some View {
        Button {
            Task {
                if let url = await model.ticketURL(ticket) { NSWorkspace.shared.open(url) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: ticket.contentType == "application/vnd.apple.pkpass" ? "wallet.pass" : "qrcode")
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 1) {
                    Text(ticket.holder ?? "Nog geen naam")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(ticket.holder == nil ? Color.orange : Color.primary)
                    Text("Kaart \(number)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
        .buttonStyle(.plain)
        .help(ticket.name)
    }
}
