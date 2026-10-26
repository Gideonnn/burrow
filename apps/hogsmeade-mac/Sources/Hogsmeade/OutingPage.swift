import AppKit
import BurrowUI
import HogsmeadeCore
import HogsmeadeUI
import SwiftUI

/// One outing: the poster fills the top with the big date and the nights
/// left; then Wanneer/Waar/Wie with the map, the tickets, Nog doen, and
/// Details for whoever wants them.
struct OutingPage: View {
    @Environment(OutingsModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let outing: Outing
    @State private var showsDetails = false
    @State private var dropping = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Hero(outing: outing)
                VStack(alignment: .leading, spacing: 16) {
                    Facts(outing: outing)
                    HStack(alignment: .top, spacing: 16) {
                        TicketsCard(outing: outing)
                        ChecklistCard(outing: outing)
                    }
                    if let lineup = outing.lineup { LineupCard(outing: outing, lineup: lineup) }
                    DisclosureGroup(isExpanded: $showsDetails) {
                        Details(outing: outing).padding(.top, 8)
                    } label: {
                        Text(showsDetails ? "Details" : "Details: mails, zoekwoorden, website…")
                            .font(.system(size: 13)).foregroundStyle(BurrowColor.hogsmeade)
                    }
                    .padding(.horizontal, 2)
                }
                .padding(EdgeInsets(top: 4, leading: 26, bottom: 30, trailing: 26))
            }
        }
        .background(BurrowColor.plaster)
        .acceptsTickets(for: outing.id, model: model, dropping: $dropping)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).strokeBorder(BurrowColor.hogsmeade, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .overlay { Text("Laat los om als kaartje te bewaren").font(.headline).padding(12).background(.regularMaterial, in: Capsule()) }
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: The top

private struct Hero: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            OutingPoster(outing: outing, symbolSize: 80, past: outing.isPast(now: model.now()))
                .overlay {
                    LinearGradient(
                        stops: [.init(color: .black.opacity(0.78), location: 0), .init(color: .black.opacity(0.35), location: 0.45), .init(color: .clear, location: 0.75)],
                        startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .bottom, endPoint: .center)
                }
            HStack(alignment: .bottom, spacing: 18) {
                DateTile(date: outing.startsAt, large: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(outing.title)
                        .font(.system(size: 40, weight: .heavy, design: .rounded)).lineLimit(2).minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
                    Text(subtitle).font(.system(size: 14)).opacity(0.9).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(nightsText)
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(hex: 0x5B2AA8))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.white.opacity(0.92), in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            }
            .foregroundStyle(.white)
            .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
        }
        .frame(height: 230)
        .clipped()
        .contextMenu { PictureMenu(outing: outing) }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let kind = outing.kind { parts.append(kind.prefix(1).uppercased() + kind.dropFirst()) }
        if !outing.allDay {
            var time = OutingFormat.time(outing.startsAt)
            if let end = outing.endsAt { time += " tot \(OutingFormat.time(end))" }
            parts.append(time)
        }
        if let venue = outing.venue { parts.append(venue) }
        return parts.joined(separator: " · ")
    }

    private var nightsText: String {
        if outing.isPast(now: model.now()) { return "Geweest" }
        let n = model.nights(until: outing)
        if n == 0 { return outing.dayWord() + "!" }
        return "Nog \(n == 1 ? "1 nachtje" : "\(n) nachtjes")"
    }
}

/// The picture's menu: pick one Hedwig found, paste one, or none.
private struct PictureMenu: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing

    var body: some View {
        Button("Plak afbeelding of link") {
            Task { await model.setPicture(NSPasteboard.general.pastedContents, for: outing.id) }
        }
        Button("Kies een gevonden afbeelding…") {
            Task {
                let options = await model.pictureOptions(for: outing.id)
                if let first = options.first { await model.choosePicture(first, for: outing.id) } else { model.show("Hedwig vond geen afbeelding bij dit uitje.") }
            }
        }
        if outing.image != nil {
            Button("Geen afbeelding") { Task { await model.removePicture(from: outing.id) } }
        }
    }
}

extension NSPasteboard {
    /// What is on the clipboard, for the picture.
    var pastedContents: PastedContents {
        var contents = PastedContents()
        for item in pasteboardItems ?? [] {
            if let data = item.data(forType: .png) ?? item.data(forType: .tiff) { contents.images.append(data) }
            if let text = item.string(forType: .fileURL), let url = URL(string: text) { contents.fileURLs.append(url) }
            if let text = item.string(forType: .URL), let url = URL(string: text) { contents.urls.append(url) }
            if let text = item.string(forType: .string) { contents.strings.append(text) }
        }
        return contents
    }
}

// MARK: Wanneer, waar, wie

private struct Facts: View {
    @Environment(OutingsModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let outing: Outing

    var body: some View {
        HStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow(alignment: .firstTextBaseline) {
                    key("Wanneer")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(OutingFormat.when(outing, now: model.now()))
                        if let times = OutingFormat.times(outing) { Text(times).font(.callout).foregroundStyle(.secondary) }
                    }
                }
                GridRow(alignment: .firstTextBaseline) {
                    key("Waar")
                    whereText
                }
                GridRow(alignment: .center) {
                    key("Wie")
                    people
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            PlaceReader(outing: outing) { place, lookingUp in
                if let place {
                    MapSnapshot(outing: outing, place: place, dark: scheme == .dark, pinTint: BurrowColor.hogsmeade)
                        .overlay(alignment: .bottomLeading) {
                            TravelTimeReader(outing: outing, place: place) { travel in
                                if let travel {
                                    Label(travel, systemImage: "car.fill").font(.caption.weight(.medium))
                                        .padding(.horizontal, 8).padding(.vertical, 5).background(.regularMaterial, in: Capsule()).padding(8)
                                }
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Button { OutingMaps.openRoute(to: place, name: outing.placeLabel(place).title) } label: {
                                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 30, height: 30).background(BurrowColor.hogsmeade, in: Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                            }
                            .buttonStyle(.plain).help("Route in Kaarten").padding(8)
                        }
                        .contextMenu {
                            if LocationAccess.shared.undecided { Button("Toon reistijd vanaf deze Mac") { LocationAccess.shared.ask() } }
                        }
                        .frame(width: 240)
                } else if lookingUp {
                    Rectangle().fill(.quaternary.opacity(0.5)).frame(width: 240).overlay { Image(systemName: "map").foregroundStyle(.tertiary) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 130)
        .background(BurrowColor.paper)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }

    private func key(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 64, alignment: .leading)
    }

    @ViewBuilder private var whereText: some View {
        let lines = OutingFormat.whereLines(outing)
        if let first = lines.first {
            VStack(alignment: .leading, spacing: 2) {
                Text(first)
                if let second = lines.dropFirst().first { Text(second).font(.callout).foregroundStyle(.secondary) }
            }
            .textSelection(.enabled)
        } else {
            Text("Nog onbekend").foregroundStyle(.secondary)
        }
    }

    private var people: some View {
        let going = Set(outing.attendees.map(\.id))
        let everyone = model.people.isEmpty ? outing.attendees.map { Person(id: $0.id, name: $0.name) } : model.people
        return HStack(spacing: 6) {
            ForEach(everyone) { person in
                let on = going.contains(person.id)
                Button { Task { await model.toggleAttendee(person, in: outing) } } label: {
                    HStack(spacing: 5) {
                        Avatar(person.name, size: 20).opacity(on ? 1 : 0.45)
                        Text(person.name).foregroundStyle(on ? .primary : .secondary)
                    }
                    .padding(.leading, 3).padding(.trailing, 9).padding(.vertical, 3)
                    .background(BurrowColor.plaster, in: Capsule())
                    .overlay(Capsule().strokeBorder(BurrowColor.hairline))
                    .opacity(on ? 1 : 0.6)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(on ? "\(person.name) gaat mee; klik om weg te halen" : "Klik als \(person.name) ook gaat")
            }
        }
        .disabled(!model.canOrganize)
    }
}

// MARK: Kaartjes

private struct TicketsCard: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    @State private var viewing: ViewingTicket?

    var body: some View {
        TicketEntriesReader(outing: outing) { entries in
            Card(title: "Kaartjes", icon: "ticket", trailing: subtitle(entries.count)) {
                if entries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(outing.shopSentence ?? "Nog geen kaartjes.").foregroundStyle(.secondary)
                        HStack {
                            ForEach(outing.shopLinks, id: \.label) { link in
                                Button {
                                    if let url = link.webURL { NSWorkspace.shared.open(url) }
                                } label: { Label(link.label.replacingOccurrences(of: "Kaartjes bij ", with: ""), systemImage: "arrow.up.right") }
                            }
                            Button("Kies bestand…") { pick() }
                        }
                        Text("Of sleep een pdf, Wallet-pas of screenshot hierheen.").font(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                                Button { viewing = ViewingTicket(index: position) } label: {
                                    TicketStub(entry: entry, label: TicketEntry.label(entry, position, of: entries.count))
                                }
                                .buttonStyle(.plain)
                                .help("Toon groot, om te scannen")
                                .contextMenu {
                                    Button(entry.ticket.personalised ? "Nog niet op naam" : "Staat op naam") {
                                        Task { await model.updateTicket(entry.ticket, in: outing.id, personalised: !entry.ticket.personalised) }
                                    }
                                    ForEach(model.people) { person in
                                        Button("Van \(person.name)") { Task { await model.updateTicket(entry.ticket, in: outing.id, holder: .some(person.name)) } }
                                    }
                                    Divider()
                                    Button("Open bestand") {
                                        Task { if let url = await model.ticketURL(entry.ticket, in: outing.id) { NSWorkspace.shared.open(url) } }
                                    }
                                    Button("Verwijder kaartje", role: .destructive) { Task { await model.deleteTicket(entry.ticket, in: outing.id) } }
                                }
                            }
                            if model.ticketUploads > 0 { ProgressView().controlSize(.small) }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .sheet(item: $viewing) { start in TicketViewer(outing: outing, entries: entries, index: start.index) }
        }
    }

    private func subtitle(_ count: Int) -> String? {
        if count == 0 { return nil }
        return [String(count), outing.vendor.map { "bij \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .image, .init(filenameExtension: "pkpass") ?? .data]
        guard panel.runModal() == .OK else { return }
        Task { await model.addTickets(panel.urls, to: outing.id) }
    }
}

/// A ticket as the design draws it: dark, a QR, the holder.
private struct TicketStub: View {
    let entry: TicketEntry
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TicketCodeFace(entry: entry, side: 44)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13, weight: .bold, design: .rounded)).lineLimit(1)
                Text(entry.ticket.personalised ? "Op naam gezet" : "Nog niet op naam").font(.system(size: 11)).opacity(0.8)
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: 150, height: 120, alignment: .topLeading)
        .background(LinearGradient(colors: [Color(hex: 0x2A1B52), Color(hex: 0x5B2AA8)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(TicketShape(notchY: 64, radius: 12), style: FillStyle(eoFill: true))
        .opacity(entry.ticket.personalised ? 1 : 0.8)
    }
}

// MARK: Nog doen

private struct ChecklistCard: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    @State private var adding = false
    @State private var title = ""
    @State private var hasDate = false
    @State private var dueAt = Date()
    @FocusState private var focused: Bool

    var body: some View {
        Card(title: "Nog doen", icon: "checkmark.circle", trailing: nil) {
            VStack(alignment: .leading, spacing: 8) {
                let items = outing.openItems().map(\.task) + outing.checklist.filter(\.done)
                if items.isEmpty && !adding { Text("Niets meer te doen.").foregroundStyle(.secondary) }
                ForEach(items) { task in row(task) }
                if adding { addField } else { addButton }
            }
            .disabled(!model.canOrganize)
        }
    }

    private func row(_ task: OutingTask) -> some View {
        let urgent = !task.done && (Calendar.current.dateComponents([.day], from: model.now(), to: task.dueAt ?? outing.startsAt).day ?? 0) < Outing.urgentDays
        return Button { Task { await model.setTask(task, done: !task.done, in: outing) } } label: {
            HStack(spacing: 10) {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(task.done ? BurrowColor.success : urgent ? BurrowColor.warning : .secondary)
                Text(task.title).strikethrough(task.done, color: .secondary).foregroundStyle(task.done ? .secondary : .primary)
                Spacer(minLength: 4)
                if let due = task.dueAt, !task.done {
                    Text(OutingFormat.due(due, now: model.now())).font(.caption.weight(.semibold)).foregroundStyle(urgent ? BurrowColor.warning : .secondary)
                } else if let by = task.doneBy {
                    Text(by.name).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addButton: some View {
        Button {
            adding = true
            dueAt = Calendar.current.date(byAdding: .day, value: -7, to: outing.startsAt).map { max($0, model.now()) } ?? model.now()
            focused = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.caption.weight(.bold)).frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3])))
                Text("Iets toevoegen")
            }
            .foregroundStyle(.secondary).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Iets toevoegen", text: $title, prompt: Text("Bijvoorbeeld oppas regelen"))
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit(add).onExitCommand { adding = false }
            HStack {
                Toggle("Vóór", isOn: $hasDate).toggleStyle(.checkbox)
                if hasDate { DatePicker("", selection: $dueAt, displayedComponents: .date).labelsHidden() }
                Spacer()
                Button("Laat maar") { adding = false; title = "" }
                Button("Voeg toe", action: add).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
    }

    private func add() {
        let text = title, due = hasDate ? dueAt : nil
        title = ""
        hasDate = false
        adding = false
        Task { await model.addTask(title: text, dueAt: due, to: outing.id) }
    }
}

// MARK: Line-up

private struct LineupCard: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    let lineup: OutingLineup

    var body: some View {
        Card(title: "Line-up", icon: "music.mic", trailing: lineup.status == .working ? "Wordt gelezen…" : lineup.updatedText(now: model.now())) {
            if lineup.status == .failed {
                Text(lineup.error ?? "Het lezen lukte niet.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(lineup.days()) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            if lineup.days().count > 1 { Text(day.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                            FlowLayout(spacing: 6) {
                                ForEach(day.headliners, id: \.name) { Text($0.name).font(.system(size: 14, weight: .bold, design: .rounded)) }
                                ForEach(day.others, id: \.name) { Text($0.name).font(.system(size: 13)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if let note = lineup.note { Text(note).font(.caption).foregroundStyle(.tertiary) }
                }
            }
        }
        .contextMenu {
            Button("Lees opnieuw") { Task { await model.refreshLineup(outing.id) } }
            Button("Haal weg") { Task { await model.removeLineup(outing.id) } }
        }
    }
}

// MARK: Details

private struct Details: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    @State private var confirmDelete = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            if let organiser = outing.organiser { row("Organisatie", organiser) }
            if let vendor = outing.vendor { row("Winkel", vendor) }
            if let order = outing.orderNumber { row("Bestelling", order) }
            if let url = outing.url, let link = URL(string: url) {
                GridRow(alignment: .firstTextBaseline) { key("Website"); Link(link.host() ?? url, destination: link) }
            }
            if !outing.aliases.isEmpty { row("Zoekwoorden", outing.aliases.joined(separator: ", ")) }
            if !outing.mails.isEmpty {
                GridRow(alignment: .firstTextBaseline) {
                    key("Mails")
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(outing.mails) { mail in
                            Text(mail.visible ? (mail.subject ?? "(zonder onderwerp)") : "Een mail van \(mail.owner.name)")
                                .foregroundStyle(mail.visible ? .primary : .secondary).lineLimit(1)
                        }
                    }
                }
            }
            if outing.offersLineup, outing.lineup == nil {
                GridRow(alignment: .firstTextBaseline) {
                    key("Line-up")
                    Button("Lees de line-up van de website") { Task { await model.refreshLineup(outing.id) } }.controlSize(.small)
                }
            }
            row("Gemaakt", "\(outing.createdBy.name), \(OutingFormat.date(outing.createdAt))")
            GridRow {
                key("")
                Button("Verwijder dit uitje", role: .destructive) { confirmDelete = true }.controlSize(.small)
                    .confirmationDialog("\(outing.title) verwijderen?", isPresented: $confirmDelete) {
                        Button("Verwijder", role: .destructive) { Task { await model.delete(outing.id) } }
                    } message: { Text("De kaartjes en mails die erbij horen gaan ook weg.") }
            }
        }
        .font(.system(size: 13))
        .textSelection(.enabled)
    }

    private func key(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 90, alignment: .leading)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow(alignment: .firstTextBaseline) { key(k); Text(v) }
    }
}

/// A white card with a heading, like the design's.
private struct Card<Content: View>: View {
    let title: String
    let icon: String
    let trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                if let trailing { Text(trailing).font(.system(size: 13)).foregroundStyle(.tertiary) }
            }
            content
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 16, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BurrowColor.paper)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}
