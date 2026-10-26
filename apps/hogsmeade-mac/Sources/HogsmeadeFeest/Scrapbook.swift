import AppKit
import BurrowUI
import HogsmeadeCore
import HogsmeadeUI
import SwiftUI

/// One outing as a page in a scrapbook: the poster with washi tape, the
/// nights as a sticker, the date as a tear-off calendar page, the facts as
/// pills, the map, Nog doen on a notepad, the ticket as a stub, the mails as
/// a clipping, and a party button for when all is set.
struct Scrapbook: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    @Binding var party: UUID?
    @State private var details = false
    @State private var dropping = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.cream.ignoresSafeArea()
            Dots().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button { model.close() } label: {
                            Label("Binnenkort", systemImage: "chevron.left").pill(.white, Palette.violet, height: 32)
                        }
                        .buttonStyle(.plain)
                        .help("Terug naar de wand (Esc)")
                        Spacer()
                        HStack(spacing: 8) {
                            UpdateBanner(appName: "Hogsmeade Feest") { (NSApp.delegate as? AppDelegate)?.restart() }
                            Button { details.toggle() } label: {
                                Text("Details").pill(details ? Palette.violet : .white, details ? .white : Palette.mutedOnCream, height: 32)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $details, arrowEdge: .bottom) { DetailsNote(outing: outing).padding(16).frame(width: 320) }
                        }
                    }
                    .padding(EdgeInsets(top: 16, leading: 100, bottom: 0, trailing: 24))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                    HStack(alignment: .top, spacing: 36) {
                        PhotoColumn(outing: outing, party: $party)
                            .frame(width: 520)
                        FactsColumn(outing: outing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(EdgeInsets(top: 30, leading: 56, bottom: 40, trailing: 36))
                }
            }
        }
        .acceptsTickets(for: outing.id, model: model, dropping: $dropping)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 24).strokeBorder(Palette.violet, style: StrokeStyle(lineWidth: 4, dash: [12]))
                    .padding(10)
                    .overlay { Text("Laat los: dat wordt een kaartje").font(.round(16, .heavy)).pill(.white, Palette.violet, height: 40) }
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The dotted paper of the scrapbook.
struct Dots: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 22
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2.4, height: 2.4)), with: .color(Color(hex: 0xE6DCC6)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: The left: the photo, the ticket, the clipping, the party

private struct PhotoColumn: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    @Binding var party: UUID?
    @State private var viewing: ViewingTicket?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ZStack(alignment: .topTrailing) {
                photo
                Sticker(colour: nightsColour, text: nightsText, size: 128, angle: 8) {
                    VStack(spacing: 2) {
                        if outing.isPast(now: model.now()) {
                            Text("geweest").font(.round(13, .heavy))
                            Text(OutingFormat.date(outing.startsAt)).font(.round(14, .black))
                        } else if model.nights(until: outing) == 0 {
                            Text(outing.dayWord().lowercased() + "!").font(.round(26, .black))
                        } else {
                            Text("nog").font(.round(13, .heavy))
                            Text(String(model.nights(until: outing))).font(.round(56, .black))
                            Text(model.nights(until: outing) == 1 ? "nachtje" : "nachtjes").font(.round(13, .heavy))
                        }
                    }
                }
                .offset(x: 30, y: -24)
            }
            tickets
            HStack(alignment: .top, spacing: 14) {
                if !outing.mails.isEmpty {
                    Label {
                        (Text(outing.mails.count == 1 ? "1 mail" : "\(outing.mails.count) mails").bold().foregroundStyle(Palette.ink) + Text(mailsFrom))
                    } icon: { Image(systemName: "envelope") }
                    .pill(.white, Palette.mutedOnCream, height: 38)
                    .rotationEffect(.degrees(-3))
                    .shadow(color: Color(hex: 0x3C280A).opacity(0.12), radius: 6, y: 3)
                }
                if !outing.isPast(now: model.now()) {
                    Button {
                        party = UUID()
                        model.show(outing.wallStamp().tone == .ok ? "Alles geregeld. Feestje!" : "Nog even, dan is alles geregeld.")
                    } label: {
                        Label(outing.wallStamp().tone == .ok ? "Alles geregeld? Vier het" : "Bijna alles geregeld", systemImage: "party.popper")
                            .font(.round(14, .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 18).frame(height: 44)
                            .background(Capsule().fill(LinearGradient(colors: [Palette.hot, Palette.violet], startPoint: .leading, endPoint: .trailing)))
                            .shadow(color: Palette.violet.opacity(0.35), radius: 12, y: 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var nightsColour: Color { outing.isPast(now: model.now()) ? Palette.mint : model.nights(until: outing) == 0 ? Palette.hot : Palette.lemon }
    private var nightsText: Color { outing.isPast(now: model.now()) ? Palette.onMint : model.nights(until: outing) == 0 ? .white : Palette.onLemon }

    private var mailsFrom: String {
        let senders = Array(Set(outing.mails.compactMap { $0.from?.name ?? $0.from?.email.split(separator: "@").last.map(String.init) })).prefix(2)
        return senders.isEmpty ? "" : " van \(senders.joined(separator: " en "))"
    }

    private var photo: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                OutingPoster(outing: outing, symbolSize: 0, stripes: true, past: outing.isPast(now: model.now()))
                if outing.image == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text([outing.venue, outing.city].compactMap { $0 }.joined(separator: " · ").uppercased())
                            .font(.poster(22)).kerning(3).foregroundStyle(.black.opacity(0.55))
                        Text(outing.title).poster(72).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.5)
                            .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
                    }
                    .padding(22)
                }
            }
            .frame(height: 340)
            .clipped()
            .contextMenu { PictureMenu(outing: outing) }
            HStack {
                Text(OutingsModel.sentence(model.others(on: outing)).map { "met \($0)" } ?? "alleen jij")
                Spacer()
                Text(outing.image == nil ? "nog geen poster" : "poster\(outing.vendor.map { " van \($0)" } ?? "")")
            }
            .font(.round(15, .semibold)).foregroundStyle(Palette.mutedOnCream)
            .padding(.horizontal, 2)
        }
        .padding(14)
        .padding(.bottom, 24)
        .background(.white)
        .rotationEffect(.degrees(-2.5))
        .shadow(color: Color(hex: 0x3C280A).opacity(0.18), radius: 18, y: 10)
        .overlay(alignment: .topLeading) { Tape(colour: Palette.mint, angle: -38).offset(x: -24, y: -8) }
        .overlay(alignment: .bottomTrailing) { Tape(colour: Palette.candy, angle: 32).offset(x: 20, y: 8) }
    }

    private var tickets: some View {
        TicketEntriesReader(outing: outing) { entries in
            HStack(alignment: .top, spacing: 16) {
                if entries.isEmpty {
                    Button { pick() } label: {
                        VStack(spacing: 4) {
                            Text(outing.shopSentence ?? "Nog geen kaartje").font(.round(14, .bold)).foregroundStyle(Palette.mutedOnCream)
                            Text("Sleep een pdf, pas of screenshot hierheen").font(.round(13, .bold)).foregroundStyle(Palette.violet)
                        }
                        .frame(width: 300, height: 118)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: 0xB8AED0), style: StrokeStyle(lineWidth: 2, dash: [8])))
                        .rotationEffect(.degrees(2))
                    }
                    .buttonStyle(.plain)
                    ForEach(outing.shopLinks, id: \.label) { link in
                        Button {
                            if let url = link.webURL { NSWorkspace.shared.open(url) }
                        } label: { Label(link.label, systemImage: "arrow.up.right").pill(.white, Palette.violet, height: 36) }
                        .buttonStyle(.plain)
                    }
                } else {
                    ForEach(Array(entries.prefix(3).enumerated()), id: \.element.id) { index, entry in
                        Button { viewing = ViewingTicket(index: index) } label: {
                            Stub(outing: outing, entry: entry, label: TicketEntry.label(entry, index, of: entries.count))
                                .rotationEffect(.degrees(index % 2 == 0 ? 2 : -2))
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
                            Button("Verwijder kaartje", role: .destructive) { Task { await model.deleteTicket(entry.ticket, in: outing.id) } }
                        }
                    }
                    if entries.count > 3 { Text("+\(entries.count - 3)").font(.round(14, .heavy)).foregroundStyle(Palette.mutedOnCream) }
                }
                if model.ticketUploads > 0 { ProgressView().controlSize(.small) }
            }
            .sheet(item: $viewing) { start in TicketViewer(outing: outing, entries: entries, index: start.index) }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .image, .init(filenameExtension: "pkpass") ?? .data]
        guard panel.runModal() == .OK else { return }
        Task { await model.addTickets(panel.urls, to: outing.id) }
    }
}

private struct PictureMenu: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing

    var body: some View {
        Button("Plak afbeelding of link") {
            Task { await model.setPicture(NSPasteboard.general.pastedContents, for: outing.id) }
        }
        Button("Kies een gevonden afbeelding") {
            Task {
                let options = await model.pictureOptions(for: outing.id)
                if let first = options.first { await model.choosePicture(first, for: outing.id) } else { model.show("Hedwig vond geen poster bij dit uitje.") }
            }
        }
        if outing.image != nil { Button("Geen afbeelding") { Task { await model.removePicture(from: outing.id) } } }
    }
}

extension NSPasteboard {
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

// MARK: The right: the facts, the calendar page, the map, the notepad

private struct FactsColumn: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            FlowLayout(spacing: 10) {
                Label(OutingFormat.when(outing, now: model.now()), systemImage: "clock").pill(Palette.lemon, Palette.onLemon, height: 40).font(.round(14, .heavy)).rotationEffect(.degrees(-2))
                if let times = OutingFormat.times(outing) {
                    Text(times).pill(.white, Palette.ink, height: 40).font(.round(14, .heavy)).rotationEffect(.degrees(1))
                }
                who
            }
            .shadow(color: Color(hex: 0x3C280A).opacity(0.12), radius: 6, y: 3)
            HStack(alignment: .top, spacing: 18) {
                CalendarPage(date: outing.startsAt)
                PlaceReader(outing: outing) { place, lookingUp in
                    if let place {
                        MapCard(outing: outing, place: place)
                    } else if lookingUp {
                        RoundedRectangle(cornerRadius: 18).fill(Color(hex: 0xEAF1E6)).frame(width: 306, height: 190).rotationEffect(.degrees(1.5))
                    } else if let first = OutingFormat.whereLines(outing).first {
                        Label(first, systemImage: "mappin.and.ellipse").pill(Palette.sky, Palette.onSky, height: 40).font(.round(14, .heavy))
                    }
                }
            }
            Notepad(outing: outing)
        }
    }

    private var who: some View {
        let going = Set(outing.attendees.map(\.id))
        let everyone = model.people.isEmpty ? outing.attendees.map { Person(id: $0.id, name: $0.name) } : model.people
        return HStack(spacing: 0) {
            HStack(spacing: -8) {
                ForEach(everyone) { person in
                    Button { Task { await model.toggleAttendee(person, in: outing) } } label: {
                        Avatar(person.name, size: 28).overlay(Circle().strokeBorder(.white, lineWidth: 2)).opacity(going.contains(person.id) ? 1 : 0.3)
                    }
                    .buttonStyle(.plain)
                    .help(going.contains(person.id) ? "\(person.name) gaat mee; klik om weg te halen" : "Klik als \(person.name) ook gaat")
                }
            }
            Text(whoText).font(.round(14, .heavy)).foregroundStyle(Palette.ink).padding(.leading, 14)
        }
        .padding(.leading, 6).padding(.trailing, 16).frame(height: 40)
        .background(Capsule().fill(.white))
        .rotationEffect(.degrees(1.5))
        .disabled(!model.canOrganize)
    }

    private var whoText: String {
        let n = outing.attendees.count
        switch n {
        case 0: return "nog niemand"
        case 1: return outing.attendees[0].id == model.myId ? "alleen jij" : "alleen \(outing.attendees[0].name)"
        case 2: return "samen"
        case 3: return "met z'n drieën"
        case 4: return "met z'n vieren"
        default: return "met z'n \(n)"
        }
    }
}

/// The date as a tear-off calendar page.
struct CalendarPage: View {
    let date: Date

    var body: some View {
        VStack(spacing: 0) {
            Text(OutingFormat.month(date).uppercased()).font(.round(12, .heavy)).kerning(1.4).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 22).background(Palette.hot)
            Text(OutingFormat.day(date)).font(.round(46, .black)).foregroundStyle(Palette.ink).padding(.top, 8).padding(.bottom, 2)
            Text(OutingFormat.weekday(date)).font(.round(12, .bold)).foregroundStyle(Palette.faintOnCream).padding(.bottom, 8)
        }
        .frame(width: 92)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .rotationEffect(.degrees(-4))
        .shadow(color: Color(hex: 0x3C280A).opacity(0.16), radius: 10, y: 6)
    }
}

/// The map as a card with the travel time and Route.
struct MapCard: View {
    let outing: Outing
    let place: OutingPlace

    var body: some View {
        ZStack(alignment: .bottom) {
            MapSnapshot(outing: outing, place: place, dark: false, pinTint: Palette.hot)
            HStack(alignment: .bottom) {
                TravelTimeReader(outing: outing, place: place) { travel in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(travel?.replacingOccurrences(of: "ca. ", with: "").replacingOccurrences(of: " met de auto", with: "") ?? outing.placeLabel(place).title)
                            .font(.round(13, .heavy)).foregroundStyle(Palette.ink).lineLimit(1)
                        Text(travel != nil ? "met de auto" : (outing.placeLabel(place).subtitle ?? "")).font(.round(11, .semibold)).foregroundStyle(Palette.mutedOnCream).lineLimit(1)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                }
                Spacer()
                Button { OutingMaps.openRoute(to: place, name: outing.placeLabel(place).title) } label: {
                    Label("Route", systemImage: "arrow.triangle.turn.up.right.diamond").pill(Palette.violet, .white, height: 34)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
        .frame(width: 306, height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .rotationEffect(.degrees(1.5))
        .shadow(color: Color(hex: 0x3C280A).opacity(0.16), radius: 12, y: 6)
        .contextMenu {
            if LocationAccess.shared.undecided { Button("Toon reistijd vanaf deze Mac") { LocationAccess.shared.ask() } }
        }
    }
}

/// Nog doen on a notepad with a lilac strip.
struct Notepad: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    @State private var adding = false
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NOG DOEN").font(.round(14, .heavy)).kerning(1).foregroundStyle(Color(hex: 0x3B2360))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).frame(height: 30).background(Palette.lilac)
            VStack(alignment: .leading, spacing: 0) {
                let items = outing.openItems().map(\.task) + outing.checklist.filter(\.done)
                if items.isEmpty && !adding {
                    Text("Niets meer te doen.").font(.round(15, .semibold)).foregroundStyle(Palette.faintOnCream).frame(height: 32)
                }
                ForEach(items) { task in row(task) }
                if adding {
                    HStack(spacing: 10) {
                        box(Palette.violet, dashed: true, mark: "+")
                        TextField("Wat moet er nog?", text: $title).textFieldStyle(.plain).font(.round(15, .semibold)).foregroundStyle(Palette.ink)
                            .focused($focused).onSubmit(add).onExitCommand { adding = false; title = "" }
                    }
                    .frame(height: 32)
                } else {
                    Button { adding = true; focused = true } label: {
                        HStack(spacing: 10) { box(Palette.violet, dashed: true, mark: "+"); Text("Iets toevoegen").font(.round(15, .semibold)).foregroundStyle(Palette.violet) }
                            .frame(height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canOrganize)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 18, bottom: 14, trailing: 18))
            .background(Lines())
        }
        .frame(width: 340)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .rotationEffect(.degrees(-1.5))
        .shadow(color: Color(hex: 0x3C280A).opacity(0.16), radius: 14, y: 8)
    }

    private func row(_ task: OutingTask) -> some View {
        Button { Task { await model.setTask(task, done: !task.done, in: outing) } } label: {
            HStack(spacing: 10) {
                box(task.done ? Palette.mint : Color(hex: 0xB8AED0), dashed: false, mark: task.done ? "✓" : "", filled: task.done)
                Text(task.title).font(.round(15, .semibold)).strikethrough(task.done).foregroundStyle(task.done ? Palette.dimOnNight : Palette.ink).lineLimit(1)
                Spacer(minLength: 6)
                if let due = task.dueAt, !task.done {
                    Text("vóór \(OutingFormat.day(due)) \(OutingFormat.month(due))").font(.round(11, .heavy)).foregroundStyle(Color(hex: 0x7A4E00))
                        .padding(.horizontal, 7).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 8).fill(Palette.lemon))
                }
            }
            .frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canOrganize)
    }

    private func box(_ colour: Color, dashed: Bool, mark: String, filled: Bool = false) -> some View {
        Text(mark).font(.round(12, .heavy)).foregroundStyle(filled ? Palette.onMint : colour)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(filled ? colour : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(colour, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3] : [])))
    }

    private func add() {
        let text = title
        title = ""
        adding = false
        Task { await model.addTask(title: text, dueAt: nil, to: outing.id) }
    }
}

/// Ruled paper.
private struct Lines: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 31
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Color(hex: 0xEAE4F3)))
                y += 32
            }
        }
    }
}

/// Details, in a popover: organiser, shop, order, website, search words, delete.
private struct DetailsNote: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let organiser = outing.organiser { row("Organisatie", organiser) }
            if let vendor = outing.vendor { row("Winkel", vendor) }
            if let order = outing.orderNumber { row("Bestelling", order) }
            if let url = outing.url, let link = URL(string: url) {
                VStack(alignment: .leading, spacing: 2) { head("Website"); Link(link.host() ?? url, destination: link).font(.round(13, .bold)) }
            }
            if !outing.aliases.isEmpty { row("Zoekwoorden", outing.aliases.joined(separator: ", ")) }
            if !outing.mails.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    head("Mails")
                    ForEach(outing.mails) { mail in
                        Text(mail.visible ? (mail.subject ?? "(zonder onderwerp)") : "Een mail van \(mail.owner.name)").font(.round(13, .semibold)).lineLimit(1)
                    }
                }
            }
            if outing.offersLineup, outing.lineup == nil {
                Button("Lees de line-up van de website") { Task { await model.refreshLineup(outing.id) } }
            }
            if let lineup = outing.lineup, lineup.status == .ready {
                VStack(alignment: .leading, spacing: 2) {
                    head("Line-up")
                    Text(lineup.artists.prefix(12).map(\.name).joined(separator: ", ")).font(.round(13, .semibold))
                }
            }
            row("Gemaakt", "\(outing.createdBy.name), \(OutingFormat.date(outing.createdAt))")
            Button("Haal dit uitje van de wand", role: .destructive) { confirmDelete = true }
                .confirmationDialog("\(outing.title) weghalen?", isPresented: $confirmDelete) {
                    Button("Haal weg", role: .destructive) { Task { await model.delete(outing.id) } }
                } message: { Text("De kaartjes en mails die erbij horen gaan ook weg.") }
        }
        .font(.round(13, .medium))
    }

    private func head(_ text: String) -> some View {
        Text(text.uppercased()).font(.round(11, .heavy)).kerning(1).foregroundStyle(Palette.faintOnCream)
    }

    private func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { head(k); Text(v).font(.round(13, .semibold)).textSelection(.enabled) }
    }
}
