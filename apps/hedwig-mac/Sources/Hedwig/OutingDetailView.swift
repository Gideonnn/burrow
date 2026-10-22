import AppKit
import HedwigCore
import SwiftUI
import UniformTypeIdentifiers

/// One outing: its picture, three facts, the one list of things to do and
/// the tickets. Everything else waits behind Details.
struct OutingDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var dropping = false
    @State private var picking: Outing?
    @State private var pageHeight: CGFloat = 900

    var body: some View {
        if let outing = model.selectedOuting {
            ScrollView {
                OutingHero(outing: outing, maxArt: min(160, max(72, pageHeight / 3 - 46))) { picking = outing }
                VStack(alignment: .leading, spacing: 22) {
                    OutingFacts(outing: outing)
                    if let lineup = outing.lineup {
                        OutingLineupCard(outing: outing, lineup: lineup)
                    } else if !outing.isPast(), outing.offersLineup {
                        LineupSearchButton(outing: outing)
                    }
                    if !outing.isPast() {
                        OutingTicketsBlock(outing: outing)
                        OutingChecklist(outing: outing)
                    } else if !outing.tickets.isEmpty || !(outing.ticketLinks ?? []).isEmpty {
                        // Looking back: the tickets stay, the to-do list does not.
                        OutingTicketsBlock(outing: outing)
                    }
                    detailsToggle
                    if model.showsOutingDetails {
                        OutingDetails(outing: outing) { picking = outing }.id(outing.id)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 28)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.pink, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .background(Color.pink.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        .overlay { Label("Laat los om als kaart te bewaren", systemImage: "ticket").font(.headline).foregroundStyle(.pink) }
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard model.me?.can(.organize) == true else { return false }
                Task { await model.addTickets(urls, to: outing.id) }
                return true
            } isTargeted: { dropping = $0 }
            .background(PasteCatcher {
                guard model.me?.can(.organize) == true else { return }
                let contents = NSPasteboard.general.pastedContents()
                Task { await model.setPicture(contents, for: outing.id) }
            })
            .sheet(item: $picking) { PicturePickerSheet(outing: $0) }
        } else {
            ContentUnavailableView("Geen evenement geselecteerd", systemImage: "ticket")
        }
    }

    private var detailsToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { model.showsOutingDetails.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("Details")
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(model.showsOutingDetails ? 180 : 0))
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Wanneer, waar, wie

private struct OutingFacts: View {
    @Environment(AppModel.self) private var model
    let outing: Outing
    @State private var lookup: (key: String, place: OutingPlace?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    key("Wanneer")
                    Text(OutingFormat.when(outing))
                    Color.clear.frame(width: 1, height: 1)
                }
                GridRow {
                    key("Waar")
                    Text(place ?? "Nog onbekend").foregroundStyle(place == nil ? .secondary : .primary).textSelection(.enabled)
                    // The map below has its own Route.
                    if let route, mapPlace == nil, !lookingUp {
                        Button { NSWorkspace.shared.open(route) } label: { Label("Route", systemImage: "map") }
                            .controlSize(.small)
                    } else {
                        Color.clear.frame(width: 1, height: 1)
                    }
                }
                GridRow(alignment: .center) {
                    key("Wie")
                    people
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            if let found = mapPlace {
                OutingMapCard(outing: outing, place: found).transition(.opacity)
            } else if lookingUp {
                OutingMapPlaceholder()
            }
        }
        .task(id: outing.placeKey) {
            guard let key = outing.placeKey, OutingMaps.book.cached(outing) == nil else { return }
            let found = await OutingMaps.book.place(for: outing)
            withAnimation(.easeOut(duration: 0.2)) { lookup = (key, found) }
        }
    }

    private func key(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }

    private var mapPlace: OutingPlace? {
        OutingMaps.book.cached(outing) ?? (lookup?.key == outing.placeKey ? lookup?.place : nil)
    }

    private var lookingUp: Bool {
        outing.placeKey != nil && lookup?.key != outing.placeKey
    }

    private var place: String? {
        let parts = [outing.venue, outing.address].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var route: URL? {
        outing.placeQueries.first.map(MapsLink.route(to:))
    }

    /// Everyone in the household; the ones going are filled in. A click
    /// adds or removes someone.
    private var people: some View {
        let going = Set(outing.attendees.map(\.id))
        let everyone = model.people.isEmpty ? outing.attendees.map { Person(id: $0.id, name: $0.name) } : model.people
        return HStack(spacing: 6) {
            ForEach(everyone) { person in
                let on = going.contains(person.id)
                Button {
                    Task { await model.toggleAttendee(person, in: outing) }
                } label: {
                    HStack(spacing: 5) {
                        Text(person.name.prefix(1))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(on ? Color.pink : Color.secondary.opacity(0.5), in: Circle())
                        Text(person.name).foregroundStyle(on ? .primary : .secondary)
                    }
                    .padding(.leading, 3).padding(.trailing, 9).padding(.vertical, 3)
                    .background(on ? Color.pink.opacity(0.12) : .clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(on ? Color.clear : Color.secondary.opacity(0.35)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(on ? "\(person.name) gaat mee; klik om weg te halen" : "Klik als \(person.name) ook gaat")
                .accessibilityLabel(on ? "\(person.name) gaat mee" : "\(person.name) gaat niet mee")
            }
        }
        .disabled(model.me?.can(.organize) != true)
    }
}

// MARK: Nog doen

private struct OutingChecklist: View {
    @Environment(AppModel.self) private var model
    let outing: Outing
    @State private var adding = false
    @State private var title = ""
    @State private var hasDate = false
    @State private var dueAt = Date()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nog doen", systemImage: "checklist").font(.headline)
            let items = outing.openItems().map(\.task) + outing.checklist.filter(\.done)
            if items.isEmpty && !adding {
                Text("Niets meer te doen.").foregroundStyle(.secondary)
            }
            ForEach(items) { task in
                ChecklistRow(task: task, outing: outing)
            }
            if adding { addField } else { addButton }
        }
        .disabled(model.me?.can(.organize) != true)
    }

    private var addButton: some View {
        Button {
            adding = true
            dueAt = Calendar.current.date(byAdding: .day, value: -7, to: outing.startsAt).map { max($0, .now) } ?? .now
            focused = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3])))
                Text("Iets toevoegen")
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addField: some View {
        HStack(spacing: 8) {
            TextField("Iets toevoegen", text: $title, prompt: Text("Bijvoorbeeld oppas regelen"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(add)
                .onExitCommand { adding = false }
            Toggle("Datum", isOn: $hasDate).toggleStyle(.checkbox)
            if hasDate {
                DatePicker("Vóór", selection: $dueAt, displayedComponents: .date).labelsHidden()
            }
            Button("Voeg toe", action: add).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            Button {
                adding = false
                title = ""
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Annuleer")
        }
    }

    private func add() {
        let text = title
        let due = hasDate ? dueAt : nil
        title = ""
        hasDate = false
        adding = false
        Task { await model.addTask(title: text, dueAt: due, to: outing.id) }
    }
}

private struct ChecklistRow: View {
    @Environment(AppModel.self) private var model
    let task: OutingTask
    let outing: Outing

    var body: some View {
        Button {
            Task { await model.setTask(task, done: !task.done, in: outing.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(task.done ? Color.green : urgent ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .strikethrough(task.done, color: .secondary)
                        .foregroundStyle(task.done ? .secondary : .primary)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(urgent ? Color.orange : Color.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.done ? "\(task.title), gedaan" : task.title)
    }

    private var urgent: Bool {
        !task.done && Calendar.current.dateComponents([.day], from: .now, to: task.dueAt ?? outing.startsAt).day ?? 0 < Outing.urgentDays
    }

    private var detail: String? {
        if let by = task.doneBy, let at = task.doneAt {
            return "\(by.name), \(OutingFormat.date(at))"
        }
        if let due = task.dueAt { return OutingFormat.due(due) }
        return task.assignee.map { "Door \($0.name)" }
    }
}

// MARK: Details

/// Everything from design v1, for whoever wants it: times and address,
/// tickets per person, mails, search words, history and delete.
private struct OutingDetails: View {
    @Environment(AppModel.self) private var model
    let outing: Outing
    let pick: () -> Void
    @State private var naming: OutingTicket?
    @State private var holder = ""
    @State private var newAlias = ""
    @State private var confirmingDelete = false

    private var canOrganize: Bool { model.me?.can(.organize) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Afbeelding") { OutingPictureSection(outing: outing, pick: pick) }
            fields.disabled(!canOrganize)
            section("Kaarten") { tickets }
            section("Mails") { mails }
            section("Zoekwoorden") { aliases.disabled(!canOrganize) }
            section("Geschiedenis") { Text(history).foregroundStyle(.secondary) }
            Button("Verwijder evenement", role: .destructive) { confirmingDelete = true }
                .foregroundStyle(.red)
                .disabled(!canOrganize)
        }
        .padding(16)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        .alert("Op wiens naam?", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Naam", text: $holder)
            Button("Bewaar") {
                if let ticket = naming {
                    let name = holder.trimmingCharacters(in: .whitespaces)
                    Task { await model.updateTicket(ticket, in: outing.id, holder: .some(name.isEmpty ? nil : name)) }
                }
            }
            Button("Annuleer", role: .cancel) {}
        }
        .confirmationDialog("\(outing.title) verwijderen?", isPresented: $confirmingDelete) {
            Button("Verwijder evenement", role: .destructive) { Task { await model.deleteOuting(outing.id) } }
        } message: {
            Text("De kaarten en de lijst verdwijnen voor iedereen. De mails blijven staan.")
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func patch(_ key: String, _ value: String, optional: Bool = true) {
        if value.isEmpty, !optional { return }
        Task { await model.updateOuting(outing.id, [key: value.isEmpty ? .null : .string(value)]) }
    }

    private func patch(_ key: String, _ date: Date?) {
        Task { await model.updateOuting(outing.id, [key: date.map { .string(APIClient.isoFractional.string(from: $0)) } ?? .null]) }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    CommitField(label: "Wat", value: outing.title) { patch("title", $0, optional: false) }
                    CommitField(label: "Soort", value: outing.kind, prompt: "concert, cabaret, feest") { patch("kind", $0) }
                }
                GridRow {
                    DateField(label: "Begint", value: outing.startsAt, components: [.date, .hourAndMinute], base: outing.startsAt) {
                        if let date = $0 { patch("startsAt", date) }
                    }
                    DateField(label: "Deuren open", value: outing.doorsAt, components: .hourAndMinute, base: outing.startsAt.addingTimeInterval(-30 * 60)) {
                        patch("doorsAt", $0)
                    }
                }
                GridRow {
                    DateField(label: "Einde", value: outing.endsAt, components: [.date, .hourAndMinute], base: outing.startsAt.addingTimeInterval(3 * 3600)) {
                        patch("endsAt", $0)
                    }
                    CommitField(label: "Zaal", value: outing.venue, prompt: "Zaal of plaats") { patch("venue", $0) }
                }
                GridRow {
                    CommitField(label: "Adres", value: outing.address, prompt: "Straat en plaats") { patch("address", $0) }
                        .gridCellColumns(2)
                }
            }
            CommitField(label: "Notities", value: outing.notes, prompt: "Waar we afspreken, wie rijdt", axis: .vertical) {
                patch("notes", $0, optional: false)
            }
        }
    }

    // MARK: Tickets per person

    private var tickets: some View {
        VStack(alignment: .leading, spacing: 6) {
            if outing.tickets.isEmpty {
                Text("Nog geen kaarten").foregroundStyle(.secondary)
            }
            ForEach(Array(outing.tickets.enumerated()), id: \.element.id) { index, ticket in
                ticketRow(ticket, number: index + 1)
            }
            Button("Kaarten toevoegen…", action: pickTickets)
                .controlSize(.small)
                .disabled(!canOrganize)
        }
    }

    private func ticketRow(_ ticket: OutingTicket, number: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ticket.contentType == "application/vnd.apple.pkpass" ? "wallet.pass" : "ticket")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Kaart \(number)")
                Text(ticket.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu(ticket.holder ?? "Geen naam") {
                ForEach(outing.attendees, id: \.id) { person in
                    Button(person.name) { Task { await model.updateTicket(ticket, in: outing.id, holder: .some(person.name)) } }
                }
                Divider()
                Button("Iemand anders…") {
                    holder = ticket.holder ?? ""
                    naming = ticket
                }
                Button("Geen naam") { Task { await model.updateTicket(ticket, in: outing.id, holder: .some(nil)) } }
            }
            .fixedSize()
            .disabled(!canOrganize)
            Toggle("op naam", isOn: Binding(
                get: { ticket.personalised },
                set: { on in Task { await model.updateTicket(ticket, in: outing.id, personalised: on) } }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .disabled(!canOrganize)
            Button("Open") {
                Task { if let url = await model.ticketURL(ticket, in: outing.id) { NSWorkspace.shared.open(url) } }
            }
            .controlSize(.small)
            Button {
                Task { await model.deleteTicket(ticket, in: outing.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Verwijder deze kaart")
            .accessibilityLabel("Verwijder kaart \(number)")
            .disabled(!canOrganize)
        }
    }

    private func pickTickets() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = AppModel.ticketExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Kies de kaarten: pdf, Wallet-pas of screenshot"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await model.addTickets(urls, to: outing.id) }
    }

    // MARK: Mails

    private var mails: some View {
        VStack(alignment: .leading, spacing: 6) {
            if outing.mails.isEmpty {
                Text("Geen mails gekoppeld").foregroundStyle(.secondary)
            }
            ForEach(outing.mails) { mail in
                if mail.visible {
                    Button {
                        Task { await model.openMail(mail.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope").foregroundStyle(.secondary)
                            Text(mail.subject ?? "(geen onderwerp)").lineLimit(1)
                            Spacer()
                            Text([mail.from?.display, OutingFormat.date(mail.receivedAt)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in Hedwig")
                } else {
                    Label("Mail van \(mail.owner.name)", systemImage: "lock")
                        .foregroundStyle(.secondary)
                        .help("Deze mail staat in de mailbox van \(mail.owner.name)")
                }
            }
        }
    }

    // MARK: Search words

    private var aliases: some View {
        FlowLayout(spacing: 6) {
            ForEach(outing.aliases, id: \.self) { alias in
                HStack(spacing: 4) {
                    Text(alias)
                    Button {
                        Task { await model.setAliases(outing.aliases.filter { $0 != alias }, in: outing.id) }
                    } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Haal \(alias) weg")
                }
                .font(.callout)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(.separator))
            }
            TextField("Zoekwoord", text: $newAlias, prompt: Text("+ zoekwoord"))
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 110)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3])))
                .onSubmit {
                    let word = newAlias.trimmingCharacters(in: .whitespaces)
                    newAlias = ""
                    guard !word.isEmpty, !outing.aliases.contains(word) else { return }
                    Task { await model.setAliases(outing.aliases + [word], in: outing.id) }
                }
        }
    }

    private var history: String {
        let added = "Toegevoegd door \(outing.createdBy.name) op \(OutingFormat.date(outing.createdAt))"
        guard outing.updatedAt.timeIntervalSince(outing.createdAt) > 60 else { return added }
        return "\(added) · laatst gewijzigd door \(outing.updatedBy.name)"
    }
}

/// A text field that saves when you press Return or leave it.
private struct CommitField: View {
    let label: String
    let value: String?
    var prompt = ""
    var axis: Axis = .horizontal
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: $text, prompt: Text(prompt), axis: axis)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .lineLimit(axis == .vertical ? 2...6 : 1...1)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { if !focused { save() } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { text = value ?? "" }
        .onChange(of: value) { if !focused { text = value ?? "" } }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (value ?? "") else { return }
        commit(trimmed)
    }
}

/// An optional date: "Voeg toe" until it has one. Changes save after a
/// short pause, so stepping through minutes is one request.
private struct DateField: View {
    let label: String
    let value: Date?
    let components: DatePickerComponents
    let base: Date
    let commit: (Date?) -> Void
    @State private var date = Date()
    @State private var pending: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if value != nil {
                HStack(spacing: 4) {
                    DatePicker(label, selection: picked, displayedComponents: components).labelsHidden()
                    if label != "Begint" {
                        Button {
                            commit(nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(label) weghalen")
                    }
                }
            } else {
                Button("Voeg toe") { commit(base) }.controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { date = value ?? base }
        .onChange(of: value) { date = value ?? base }
    }

    // Only what the person picks is saved, not the value shown on appear.
    private var picked: Binding<Date> {
        Binding(
            get: { date },
            set: { new in
                date = new
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(900))
                    guard !Task.isCancelled, new != value else { return }
                    commit(new)
                }
            })
    }
}

/// Chips that wrap onto the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
