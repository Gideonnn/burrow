import AppKit
import BurrowUI
import HogsmeadeCore
import HogsmeadeUI
import QuickLook
import SwiftUI

/// One outing: the poster fills the top with the big date and the nights
/// left; then Wanneer/Waar/Wie with the map, the tickets, Nog doen, and
/// Details for whoever wants them.
struct OutingPage: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    @SceneStorage("hogsmeade.details") private var showsDetails = false
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
                    }
                    .padding(.horizontal, 2)
                }
                .padding(EdgeInsets(top: 4, leading: 26, bottom: 30, trailing: 26))
            }
        }
        .acceptsTickets(for: outing.id, model: model, dropping: $dropping)
        .onPasteCommand(of: [.image, .png, .tiff, .fileURL, .url]) { _ in
            guard model.canOrganize else { return }
            Task { await model.setPicture(NSPasteboard.general.pastedContents, for: outing.id) }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .overlay {
                        Text("Laat los om als kaartje te bewaren").font(.headline)
                            .padding(12).modifier(Glass(shape: Capsule()))
                    }
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
                .modifier(ExtendsBehindSidebar())
            HStack(alignment: .bottom, spacing: 18) {
                DateTile(date: outing.startsAt, large: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(outing.title)
                        .font(.largeTitle.weight(.heavy)).fontDesign(.rounded).lineLimit(2).minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
                    Text(subtitle).font(.callout).opacity(0.9).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(nightsText)
                    .font(.headline).fontDesign(.rounded)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
        }
        .frame(height: 230)
        .clipped()
        .environment(\.colorScheme, .dark)
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

/// The poster runs on under the sidebar from macOS 26.
private struct ExtendsBehindSidebar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.backgroundExtensionEffect()
        } else {
            content
        }
    }
}

/// The picture's menu: choose one, paste one, or none.
struct PictureMenu: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing

    var body: some View {
        Button("Kies een afbeelding…") { model.pickingPictureId = outing.id }
        Button("Plak afbeelding of link") {
            Task { await model.setPicture(NSPasteboard.general.pastedContents, for: outing.id) }
        }
        if outing.image != nil {
            Button("Geen afbeelding") { Task { await model.removePicture(from: outing.id) } }
        }
    }
}

/// A poster's menu on the wall.
struct OutingMenu: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing

    var body: some View {
        Button("Open") { model.open(outing.id) }
        Button("Wijzig…") { model.editingId = outing.id }.disabled(!model.canOrganize)
        Divider()
        PictureMenu(outing: outing).disabled(!model.canOrganize)
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
                if !outing.notes.isEmpty {
                    GridRow(alignment: .firstTextBaseline) {
                        key("Notities")
                        Text(outing.notes).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
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
                                        .padding(.horizontal, 8).padding(.vertical, 5).modifier(Glass(shape: Capsule())).padding(8)
                                }
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Button { OutingMaps.openRoute(to: place, name: outing.placeLabel(place).title) } label: {
                                Label("Route in Kaarten", systemImage: "arrow.triangle.turn.up.right.diamond.fill").labelStyle(.iconOnly)
                            }
                            .modifier(MapButtonStyle())
                            .help("Route in Kaarten")
                            .padding(8)
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
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func key(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
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
                Toggle(isOn: Binding(get: { on }, set: { _ in Task { await model.toggleAttendee(person, in: outing) } })) {
                    Label { Text(person.name) } icon: { Avatar(person.name, size: 16).opacity(on ? 1 : 0.5) }
                }
                .toggleStyle(.button)
                .help(on ? "\(person.name) gaat mee; klik om weg te halen" : "Klik als \(person.name) ook gaat")
                .accessibilityLabel(on ? "\(person.name) gaat mee" : "\(person.name) gaat niet mee")
            }
        }
        .disabled(!model.canOrganize)
    }
}

/// Glass on the map from macOS 26, a bordered circle before.
private struct MapButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
        }
    }
}

// MARK: Kaartjes

private struct TicketsCard: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    @State private var viewing: ViewingTicket?
    @State private var lookingAt: URL?
    @State private var naming: OutingTicket?
    @State private var holder = ""

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
                            Button("Kies bestand…") { pick() }.disabled(!model.canOrganize)
                        }
                        Text("Of sleep een pdf, Wallet-pas of screenshot hierheen.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                                Button { viewing = ViewingTicket(index: position) } label: {
                                    TicketStub(entry: entry, label: TicketEntry.label(entry, position, of: entries.count))
                                }
                                .buttonStyle(.borderless)
                                .help("Toon groot, om te scannen")
                                .contextMenu { menu(entry.ticket) }
                            }
                            if model.ticketUploads > 0 { ProgressView().controlSize(.small) }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .sheet(item: $viewing) { start in TicketViewer(outing: outing, entries: entries, index: start.index) }
        }
        .quickLookPreview($lookingAt)
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
    }

    @ViewBuilder private func menu(_ ticket: OutingTicket) -> some View {
        Button("Quick Look") { Task { lookingAt = await model.ticketURL(ticket, in: outing.id) } }
        Button("Open bestand") {
            Task { if let url = await model.ticketURL(ticket, in: outing.id) { NSWorkspace.shared.open(url) } }
        }
        Divider()
        Group {
            Toggle("Staat op naam", isOn: Binding(
                get: { ticket.personalised },
                set: { on in Task { await model.updateTicket(ticket, in: outing.id, personalised: on) } }))
            Menu("Van") {
                ForEach(model.people) { person in
                    Button(person.name) { Task { await model.updateTicket(ticket, in: outing.id, holder: .some(person.name)) } }
                }
                Divider()
                Button("Iemand anders…") {
                    holder = ticket.holder ?? ""
                    naming = ticket
                }
                Button("Geen naam") { Task { await model.updateTicket(ticket, in: outing.id, holder: .some(nil)) } }
            }
            Divider()
            Button("Verwijder kaartje", role: .destructive) { Task { await model.deleteTicket(ticket, in: outing.id) } }
        }
        .disabled(!model.canOrganize)
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
                Text(label).font(.subheadline.bold()).fontDesign(.rounded).lineLimit(1)
                Text(entry.ticket.personalised ? "Op naam gezet" : "Nog niet op naam").font(.caption2).opacity(0.8)
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
    @State private var title = ""
    @State private var hasDate = false
    @State private var dueAt = Date()

    var body: some View {
        Card(title: "Nog doen", icon: "checklist", trailing: nil) {
            VStack(alignment: .leading, spacing: 8) {
                let items = outing.openItems().map(\.task) + outing.checklist.filter(\.done)
                if items.isEmpty { Text("Niets meer te doen.").foregroundStyle(.secondary) }
                ForEach(items) { task in row(task) }
                addField
            }
            .disabled(!model.canOrganize)
        }
    }

    private func row(_ task: OutingTask) -> some View {
        let urgent = !task.done && (Calendar.current.dateComponents([.day], from: model.now(), to: task.dueAt ?? outing.startsAt).day ?? 0) < Outing.urgentDays
        return HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(get: { task.done }, set: { done in Task { await model.setTask(task, done: done, in: outing) } })) {
                Text(task.title).strikethrough(task.done, color: .secondary).foregroundStyle(task.done ? .secondary : .primary)
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 4)
            if let due = task.dueAt, !task.done {
                Text(OutingFormat.due(due, now: model.now())).font(.caption.weight(.semibold))
                    .foregroundStyle(urgent ? AnyShapeStyle(BurrowColor.warning) : AnyShapeStyle(.secondary))
            } else if let by = task.doneBy {
                Text(by.name).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var addField: some View {
        HStack {
            TextField("Iets toevoegen", text: $title, prompt: Text("Iets toevoegen, bijvoorbeeld oppas regelen"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Toggle("Vóór", isOn: $hasDate).toggleStyle(.checkbox)
                .onChange(of: hasDate) {
                    if hasDate {
                        dueAt = Calendar.current.date(byAdding: .day, value: -7, to: outing.startsAt).map { max($0, model.now()) } ?? model.now()
                    }
                }
            if hasDate { DatePicker("Vóór", selection: $dueAt, displayedComponents: .date).labelsHidden() }
        }
        .controlSize(.small)
    }

    private func add() {
        let text = title, due = hasDate ? dueAt : nil
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        title = ""
        hasDate = false
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
                HStack {
                    Label(lineup.error ?? "Het lezen lukte niet.", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Probeer opnieuw") { Task { await model.refreshLineup(outing.id) } }.disabled(!model.canOrganize)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(lineup.days()) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            if lineup.days().count > 1 { Text(day.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                            FlowLayout(spacing: 6) {
                                ForEach(day.headliners, id: \.name) { Text($0.name).font(.body.bold()).fontDesign(.rounded) }
                                ForEach(day.others, id: \.name) { Text($0.name).font(.subheadline).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        if let note = lineup.note { Text(note).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        if let host = lineup.sourceHost, let url = lineup.sourceURL {
                            Link("Bron: \(host)", destination: url).help(url.absoluteString)
                        }
                    }
                    .font(.caption)
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
    @State private var reading: MailRef?
    @State private var newAlias = ""

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            if let organiser = outing.organiser { row("Organisatie", organiser) }
            if let vendor = outing.vendor { row("Winkel", vendor) }
            if let order = outing.orderNumber { row("Bestelling", order) }
            if let url = outing.url, let link = URL(string: url) {
                GridRow(alignment: .firstTextBaseline) { key("Website"); Link(link.host() ?? url, destination: link) }
            }
            GridRow(alignment: .firstTextBaseline) {
                key("Mails")
                mails
            }
            GridRow(alignment: .firstTextBaseline) {
                key("Zoekwoorden")
                aliases.disabled(!model.canOrganize)
            }
            if outing.offersLineup, outing.lineup == nil {
                GridRow(alignment: .firstTextBaseline) {
                    key("Line-up")
                    Button("Lees de line-up van de website") { Task { await model.refreshLineup(outing.id) } }
                        .controlSize(.small).disabled(!model.canOrganize)
                }
            }
            row("Geschiedenis", history)
            GridRow {
                key("")
                HStack {
                    Button("Wijzig…") { model.editingId = outing.id }
                    Button("Verwijder dit uitje", role: .destructive) { confirmDelete = true }
                }
                .controlSize(.small)
                .disabled(!model.canOrganize)
                .confirmationDialog("\(outing.title) verwijderen?", isPresented: $confirmDelete) {
                    Button("Verwijder", role: .destructive) { Task { await model.delete(outing.id) } }
                } message: { Text("De kaartjes en mails die erbij horen gaan ook weg.") }
            }
        }
        .textSelection(.enabled)
        .sheet(item: $reading) { MailSheet(mail: $0.mail) }
    }

    private func key(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow(alignment: .firstTextBaseline) { key(k); Text(v) }
    }

    @ViewBuilder private var mails: some View {
        if outing.mails.isEmpty {
            Text("Geen mails gekoppeld").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(outing.mails) { mail in
                    if mail.visible {
                        HStack(spacing: 6) {
                            Button { reading = MailRef(mail: mail) } label: {
                                Label(mail.subject ?? "(zonder onderwerp)", systemImage: "envelope").lineLimit(1)
                            }
                            .buttonStyle(.link)
                            .help("Lees de mail")
                            Text([mail.from?.display, OutingFormat.date(mail.receivedAt)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Menu {
                                mailMenu(mail)
                            } label: {
                                Label("Meer", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .disabled(!model.canOrganize)
                            .accessibilityLabel("Meer voor \(mail.subject ?? "deze mail")")
                        }
                        .contextMenu { mailMenu(mail) }
                    } else {
                        Label("Een mail van \(mail.owner.name)", systemImage: "lock").foregroundStyle(.secondary)
                            .help("Deze mail staat in de mailbox van \(mail.owner.name)")
                    }
                }
            }
        }
    }

    @ViewBuilder private func mailMenu(_ mail: OutingMail) -> some View {
        Button("Lees") { reading = MailRef(mail: mail) }
        Menu("Verplaats naar") {
            ForEach(model.upcoming.filter { $0.id != outing.id } + model.past.filter { $0.id != outing.id }) { other in
                Button("\(other.title), \(OutingFormat.date(other.startsAt))") {
                    Task { await model.moveMail(mail.id, from: outing.id, to: other.id) }
                }
            }
        }
        .disabled(!model.canOrganize)
        Button("Maak los van dit uitje") { Task { await model.unlinkMail(mail.id, from: outing.id) } }
            .disabled(!model.canOrganize)
    }

    private var aliases: some View {
        FlowLayout(spacing: 6) {
            ForEach(outing.aliases, id: \.self) { alias in
                Button {
                    Task { await model.setAliases(outing.aliases.filter { $0 != alias }, in: outing.id) }
                } label: {
                    Label(alias, systemImage: "xmark").labelStyle(TrailingIcon())
                }
                .controlSize(.small)
                .help("Haal \(alias) weg")
                .accessibilityLabel("Haal zoekwoord \(alias) weg")
            }
            TextField("Zoekwoord", text: $newAlias, prompt: Text("Nieuw zoekwoord"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 140)
                .onSubmit {
                    let word = newAlias
                    newAlias = ""
                    Task { await model.setAliases(outing.aliases + [word], in: outing.id) }
                }
        }
    }

    private var history: String {
        let added = "Toegevoegd door \(outing.createdBy.name) op \(OutingFormat.date(outing.createdAt))"
        guard outing.updatedAt.timeIntervalSince(outing.createdAt) > 60 else { return added }
        return "\(added), laatst gewijzigd door \(outing.updatedBy.name)"
    }
}

private struct MailRef: Identifiable {
    let mail: OutingMail
    var id: String { mail.id }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small).foregroundStyle(.secondary)
        }
    }
}

/// A section of the page with a heading.
private struct Card<Content: View>: View {
    let title: String
    let icon: String
    let trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon).font(.headline)
                if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 16, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
