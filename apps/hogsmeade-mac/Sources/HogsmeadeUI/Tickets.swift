import AppKit
import HogsmeadeCore
import SwiftUI
import UniformTypeIdentifiers

// Tickets as Hedwig reads them: a Wallet pass in its own colours, or the
// code cut from a pdf or screenshot, and a big view to scan at the door.

public enum TicketPreview: @unchecked Sendable {
    case pass(TicketPass, code: CGImage?)
    case codes([TicketCode])
    /// No code found: a plain card with the file's name.
    case file
}

@MainActor
public enum TicketPreviews {
    private static var previews: [String: TicketPreview] = [:]
    private static var order: [String] = []

    public static func cached(_ ticket: OutingTicket) -> TicketPreview? { previews[ticket.id] }

    /// Nil when the file could not be fetched, so it is tried again later.
    public static func load(_ ticket: OutingTicket, in outingId: String, model: OutingsModel) async -> TicketPreview? {
        if let hit = previews[ticket.id] { return hit }
        guard let data = await model.ticketData(ticket, in: outingId) else { return nil }
        let type = ticket.contentType, ext = (ticket.name as NSString).pathExtension.lowercased()
        let preview = await Task.detached(priority: .userInitiated) { () -> TicketPreview in
            if type == "application/vnd.apple.pkpass" || ext == "pkpass" {
                guard let pass = TicketPass(pkpass: data) else { return .file }
                return .pass(pass, code: pass.barcode?.image())
            }
            let codes = type == "application/pdf" || ext == "pdf" ? TicketCodes.find(pdf: data) : TicketCodes.find(imageData: data)
            return codes.isEmpty ? .file : .codes(codes)
        }.value
        previews[ticket.id] = preview
        order.append(ticket.id)
        while order.count > 60 { previews[order.removeFirst()] = nil }
        return preview
    }
}

/// One card: a ticket's pass, one of its codes, or the file itself.
public struct TicketEntry: Identifiable {
    public enum Face {
        case pass(TicketPass, code: CGImage?)
        case code(TicketCode)
        case file
        case loading
    }

    public let ticket: OutingTicket
    public let face: Face
    public let index: Int
    public var id: String { "\(ticket.id)#\(index)" }

    public static func all(_ tickets: [OutingTicket], _ previews: [String: TicketPreview]) -> [TicketEntry] {
        let entries = everyFace(tickets, previews)
        let keep = TicketDedupe.keep(entries.map { entry in
            switch entry.face {
            case let .pass(pass, _): .init(payload: pass.barcode?.message, isPass: true)
            case let .code(code): .init(payload: code.payload, isPass: false)
            case .file, .loading: .init(payload: nil, isPass: false)
            }
        })
        return zip(entries, keep).filter(\.1).map(\.0)
    }

    private static func everyFace(_ tickets: [OutingTicket], _ previews: [String: TicketPreview]) -> [TicketEntry] {
        tickets.flatMap { ticket -> [TicketEntry] in
            switch previews[ticket.id] {
            case let .pass(pass, code): [TicketEntry(ticket: ticket, face: .pass(pass, code: code), index: 0)]
            case let .codes(codes): codes.enumerated().map { TicketEntry(ticket: ticket, face: .code($1), index: $0) }
            case .file: [TicketEntry(ticket: ticket, face: .file, index: 0)]
            case nil: [TicketEntry(ticket: ticket, face: .loading, index: 0)]
            }
        }
    }

    /// The holder's name, or "Kaartje 2/3" counted over every card.
    public static func label(_ entry: TicketEntry, _ position: Int, of count: Int) -> String {
        entry.ticket.holder ?? (count == 1 ? "Kaartje" : "Kaartje \(position + 1)/\(count)")
    }

    /// The holder's first name, or "1/2".
    public static func shortLabel(_ entry: TicketEntry, _ position: Int, of count: Int) -> String {
        if let holder = entry.ticket.holder { return holder.split(separator: " ").first.map(String.init) ?? holder }
        return count == 1 ? "Kaartje" : "\(position + 1)/\(count)"
    }
}

extension PassColour {
    public var color: Color { Color(red: red, green: green, blue: blue) }
}

/// Loads the codes of an outing's tickets and hands the cards to `content`.
public struct TicketEntriesReader<Content: View>: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    let content: ([TicketEntry]) -> Content
    @State private var previews: [String: TicketPreview] = [:]

    public init(outing: Outing, @ViewBuilder content: @escaping ([TicketEntry]) -> Content) {
        self.outing = outing
        self.content = content
    }

    public var body: some View {
        content(TicketEntry.all(outing.tickets, previews))
            .task(id: outing.tickets.map(\.id)) {
                for ticket in outing.tickets where previews[ticket.id] == nil {
                    if let hit = TicketPreviews.cached(ticket) {
                        previews[ticket.id] = hit
                    } else if let preview = await TicketPreviews.load(ticket, in: outing.id, model: model) {
                        previews[ticket.id] = preview
                    }
                }
            }
    }
}

/// A rounded ticket with a notch on each side, where Wallet tears it.
public struct TicketShape: Shape {
    var notchY: CGFloat
    var radius: CGFloat
    var notch: CGFloat

    public init(notchY: CGFloat, radius: CGFloat = 14, notch: CGFloat = 7) {
        self.notchY = notchY
        self.radius = radius
        self.notch = notch
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: radius)
        path.addEllipse(in: CGRect(x: rect.minX - notch, y: rect.minY + notchY - notch, width: notch * 2, height: notch * 2))
        path.addEllipse(in: CGRect(x: rect.maxX - notch, y: rect.minY + notchY - notch, width: notch * 2, height: notch * 2))
        return path
    }
}

/// Only the code, on white, the same for a pass, a PDF or a picture.
public struct TicketCodeFace: View {
    let entry: TicketEntry
    var side: CGFloat

    public init(entry: TicketEntry, side: CGFloat = 60) {
        self.entry = entry
        self.side = side
    }

    public var body: some View {
        switch entry.face {
        case let .pass(_, code):
            Color.white.overlay {
                if let code {
                    Image(decorative: code, scale: 1).interpolation(.none).resizable().scaledToFit().frame(width: side, height: side)
                } else {
                    Image(systemName: "wallet.pass").font(.system(size: side * 0.4, weight: .light)).foregroundStyle(.secondary)
                }
            }
        case let .code(code):
            Color.white.overlay { CodeView(code: code, side: side) }
        case .file:
            Color.secondary.opacity(0.1).overlay {
                Image(systemName: entry.ticket.contentType == "application/pdf" ? "doc.richtext" : "photo")
                    .font(.system(size: side * 0.4, weight: .light))
                    .foregroundStyle(.secondary)
            }
        case .loading:
            Color.secondary.opacity(0.1).overlay { ProgressView().controlSize(.small) }
        }
    }
}

/// A code on white with a quiet zone around it; a redrawn code is scaled
/// module by module, never smoothed, so a scanner reads it from the screen.
public struct CodeView: View {
    let code: TicketCode
    let side: CGFloat

    public init(code: TicketCode, side: CGFloat) {
        self.code = code
        self.side = side
    }

    public var body: some View {
        Image(decorative: code.image, scale: 1)
            .interpolation(code.crisp ? .none : .high)
            .resizable()
            .aspectRatio(CGFloat(code.image.width) / CGFloat(code.image.height), contentMode: .fit)
            .frame(maxWidth: code.isSquare ? side : side * 2.4, maxHeight: code.isSquare ? side : side * 0.9)
            .padding(side * 0.08)
            .background(.white)
    }
}

/// A Wallet pass in its own colours with its code on white.
public struct PassFace: View {
    let pass: TicketPass
    let code: CGImage?
    let codeSide: CGFloat

    public init(pass: TicketPass, code: CGImage?, codeSide: CGFloat) {
        self.pass = pass
        self.code = code
        self.codeSide = codeSide
    }

    public var body: some View {
        let foreground = pass.foreground?.color ?? .white
        VStack(spacing: 14) {
            VStack(spacing: 1) {
                if let organisation = pass.organisation {
                    Text(organisation.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).opacity(0.8).lineLimit(1)
                }
                if let title = pass.title { Text(title).font(.title2.weight(.bold)).lineLimit(2) }
            }
            .multilineTextAlignment(.center)
            if !pass.fields.isEmpty {
                HStack(spacing: 22) {
                    ForEach(pass.fields, id: \.self) { field in
                        VStack(spacing: 1) {
                            if let label = field.label { Text(label.uppercased()).font(.caption2.weight(.semibold)).opacity(0.75) }
                            Text(field.value).font(.headline)
                        }
                    }
                }
            }
            if let code, let barcode = pass.barcode {
                CodeView(code: TicketCode(kind: barcode.format.kind, payload: barcode.message, image: code, crisp: true), side: codeSide)
                    .background(.white, in: RoundedRectangle(cornerRadius: codeSide * 0.08))
                if let alt = barcode.altText { Text(alt).font(.callout.monospaced()).opacity(0.85) }
            }
        }
        .foregroundStyle(foreground)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pass.background?.color ?? Color(red: 0.55, green: 0.12, blue: 0.32))
    }
}

extension PassBarcode.Format {
    public var kind: TicketCode.Kind {
        switch self {
        case .qr: .qr
        case .pdf417: .pdf417
        case .aztec: .aztec
        case .code128: .code128
        }
    }
}

/// Big, for the door: one card at a time, arrows between them.
public struct TicketViewer: View {
    @Environment(OutingsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let outing: Outing
    let entries: [TicketEntry]
    @State var index: Int

    public init(outing: Outing, entries: [TicketEntry], index: Int) {
        self.outing = outing
        self.entries = entries
        _index = State(initialValue: index)
    }

    private var entry: TicketEntry? { entries.indices.contains(index) ? entries[index] : nil }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 640)
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if entries.count > 1 {
                Button { _ = step(-1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0).accessibilityLabel("Vorige")
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.map { TicketEntry.label($0, index, of: entries.count) } ?? "Kaartje").font(.headline)
                Text([outing.title, entry?.ticket.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if entries.count > 1 {
                Button { _ = step(1) } label: { Image(systemName: "chevron.right") }.disabled(index >= entries.count - 1).accessibilityLabel("Volgende")
            }
            Spacer()
            Button("Open bestand") {
                guard let ticket = entry?.ticket else { return }
                Task { if let url = await model.ticketURL(ticket, in: outing.id) { NSWorkspace.shared.open(url) } }
            }
            Button("Klaar") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    @ViewBuilder private var content: some View {
        switch entry?.face {
        case let .pass(pass, code): PassFace(pass: pass, code: code, codeSide: 300)
        case let .code(code): Color.white.overlay { CodeView(code: code, side: 380) }
        case .file, nil: ContentUnavailableView("Geen code gevonden", systemImage: "ticket", description: Text("Open het bestand om de kaart te tonen."))
        case .loading: ProgressView()
        }
    }

    private func step(_ by: Int) -> KeyPress.Result {
        let next = index + by
        guard entries.indices.contains(next) else { return .ignored }
        index = next
        return .handled
    }
}

/// Which card is being viewed big.
public struct ViewingTicket: Identifiable {
    public let index: Int
    public var id: Int { index }
    public init(index: Int) { self.index = index }
}

/// Dropped files become tickets of the outing.
extension View {
    public func acceptsTickets(for outingId: String, model: OutingsModel, dropping: Binding<Bool>? = nil) -> some View {
        onDrop(of: [.fileURL], isTargeted: dropping) { providers in
            Task {
                var files: [URL] = []
                for provider in providers {
                    if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        files.append(url)
                    }
                }
                if !files.isEmpty { await model.addTickets(files, to: outingId) }
            }
            return true
        }
    }
}

/// Nieuw uitje: what, when and where. Tickets dropped on the sheet follow.
public struct NewOutingSheet: View {
    @Environment(OutingsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind = ""
    @State private var startsAt = NewOutingSheet.nextEvening()
    @State private var venue = ""
    @State private var saving = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nieuw uitje").font(.title2.weight(.semibold))
            Text("Meestal hoeft dit niet: Hedwig ziet de bevestigingsmail en hangt het uitje vanzelf aan de wand. Alleen voor iets zonder mail.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Wat", text: $title, prompt: Text("Bijvoorbeeld Schaatsen op de Jaap Eden"))
                TextField("Soort", text: $kind, prompt: Text("concert, theater, feest…"))
                DatePicker("Wanneer", selection: $startsAt)
                TextField("Waar", text: $venue, prompt: Text("Zaal of adres"))
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Laat maar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Hang aan de wand") {
                    saving = true
                    Task {
                        await model.create(title: title, startsAt: startsAt, venue: venue, kind: kind)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    /// Tomorrow at eight.
    public static func nextEvening(now: Date = .now, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}
