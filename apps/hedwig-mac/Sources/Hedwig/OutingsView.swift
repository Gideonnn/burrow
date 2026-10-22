import HedwigCore
import SwiftUI
import UniformTypeIdentifiers

/// Evenementen: the household's outings, each with one sentence about its
/// state (design v2). No filters or tabs: upcoming first, then Geweest.
struct OutingListView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedOutingId) {
            Button { adding = true } label: {
                Label("Evenement toevoegen", systemImage: "plus")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(model.me?.can(.organize) != true)
            .selectionDisabled()
            ForEach(model.upcomingOutings) { outing in
                OutingRow(outing: outing).tag(outing.id)
            }
            if !model.pastOutings.isEmpty {
                Section("Geweest") {
                    ForEach(model.pastOutings) { outing in
                        OutingRow(outing: outing, past: true).tag(outing.id).opacity(0.6)
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.outings.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "Nog geen evenementen", systemImage: "ticket",
                    description: Text("Hedwig bewaart ze uit bestelmails, of voeg er zelf een toe."))
            }
        }
        .navigationTitle("Evenementen")
        .sheet(isPresented: $adding) { NewOutingSheet() }
        .task { await model.loadPeople() }
    }
}

private struct OutingRow: View {
    let outing: Outing
    var past = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OutingDateTile(date: outing.startsAt)
            VStack(alignment: .leading, spacing: 2) {
                Text(outing.title).font(.headline).lineLimit(1)
                Text([OutingFormat.when(outing), outing.venue].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                OutingStatusLine(status: outing.status())
            }
            Spacer(minLength: 0)
            OutingThumbnail(outing: outing, past: past).frame(maxHeight: .infinity)
        }
        .padding(.vertical, 4)
    }
}

struct OutingStatusLine: View {
    let status: OutingStatus

    var body: some View {
        Label(status.text, systemImage: icon)
            .font(.callout.weight(status.tone == .later || status.tone == .past ? .regular : .medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var icon: String {
        switch status.tone {
        case .today: "bolt.fill"
        case .todo: "exclamationmark.circle.fill"
        case .later: "clock"
        case .done: "checkmark.circle.fill"
        case .past: "clock.arrow.circlepath"
        }
    }

    private var color: Color {
        switch status.tone {
        case .today: .pink
        case .todo: .orange
        case .later, .past: .secondary
        case .done: .green
        }
    }
}

/// Month small, day large, like a tear-off calendar.
struct OutingDateTile: View {
    let date: Date
    var large = false

    var body: some View {
        VStack(spacing: 0) {
            Text(OutingFormat.month(date).uppercased())
                .font(.system(size: large ? 11 : 9, weight: .bold))
                .foregroundStyle(.pink)
            Text(OutingFormat.day(date))
                .font(.system(size: large ? 26 : 18, weight: .semibold))
                .monospacedDigit()
        }
        .frame(width: large ? 58 : 40, height: large ? 58 : 40)
        .background(.background, in: RoundedRectangle(cornerRadius: large ? 12 : 8))
        .overlay(RoundedRectangle(cornerRadius: large ? 12 : 8).strokeBorder(.separator))
    }
}

/// Nieuw evenement: three fields. A pdf or screenshot dropped here becomes a
/// ticket once the outing is saved.
struct NewOutingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var startsAt = NewOutingSheet.nextEvening()
    @State private var venue = ""
    @State private var tickets: [URL] = []
    @State private var dropping = false
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nieuw evenement").font(.title2.weight(.semibold))
            Form {
                TextField("Wat", text: $title, prompt: Text("Cabaret, concert, feest"))
                DatePicker("Wanneer", selection: $startsAt, displayedComponents: [.date, .hourAndMinute])
                TextField("Waar", text: $venue, prompt: Text("Zaal of plaats"))
            }
            .formStyle(.columns)
            dropZone
            HStack {
                Spacer()
                Button("Annuleer", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Bewaar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 440)
        .dropDestination(for: URL.self) { urls, _ in
            tickets += urls.filter { AppModel.ticketExtensions.contains($0.pathExtension.lowercased()) }
            return true
        } isTargeted: { dropping = $0 }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            if tickets.isEmpty {
                Label("Sleep kaarten hierheen: pdf, Wallet-pas of screenshot", systemImage: "arrow.down.doc")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tickets, id: \.self) { url in
                    HStack {
                        Label(url.lastPathComponent, systemImage: "ticket").lineLimit(1)
                        Spacer()
                        Button {
                            tickets.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Haal weg")
                    }
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, minHeight: 54)
        .padding(10)
        .background(dropping ? Color.pink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(dropping ? Color.pink : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4])))
    }

    private func save() {
        saving = true
        Task {
            let created = await model.createOuting(title: title, startsAt: startsAt, venue: venue, tickets: tickets)
            saving = false
            if created != nil { dismiss() }
        }
    }

    /// Tonight at eight, or tomorrow when that has passed.
    static func nextEvening(now: Date = .now) -> Date {
        let calendar = Calendar.current
        let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now
        return tonight > now ? tonight : calendar.date(byAdding: .day, value: 1, to: tonight) ?? tonight
    }
}
