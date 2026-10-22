import AppKit
import HedwigCore
import SwiftUI

// The tickets on an outing's page: one card per code (a Wallet pass in its
// own colours, or the QR code cut neatly from a pdf or screenshot), a big
// view to scan at the door, and the shop pages for tickets that came as a link.

enum TicketPreview {
    case pass(TicketPass, code: CGImage?)
    case codes([TicketCode])
    /// No code found: a plain card with the file's name.
    case file
}

@MainActor
enum TicketPreviews {
    private static var previews: [String: TicketPreview] = [:]
    private static var order: [String] = []

    static func cached(_ ticket: OutingTicket) -> TicketPreview? { previews[ticket.id] }

    /// Nil when the file could not be fetched, so it is tried again later.
    static func load(_ ticket: OutingTicket, in outingId: String, model: AppModel) async -> TicketPreview? {
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
struct TicketEntry: Identifiable {
    enum Face {
        case pass(TicketPass, code: CGImage?)
        case code(TicketCode)
        case file
        case loading
    }

    let ticket: OutingTicket
    let face: Face
    let index: Int
    var id: String { "\(ticket.id)#\(index)" }

    static func all(_ tickets: [OutingTicket], _ previews: [String: TicketPreview]) -> [TicketEntry] {
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
}

extension PassColour {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

// MARK: The block on the page

struct OutingTicketsBlock: View {
    @Environment(AppModel.self) private var model
    let outing: Outing
    @State private var previews: [String: TicketPreview] = [:]
    @State private var viewing: ViewingTicket?

    var body: some View {
        let count = outing.tickets.count
        let links = outing.shopLinks
        let entries = TicketEntry.all(outing.tickets, previews)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: count == 0 && links.isEmpty ? "ticket" : "ticket.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(count == 0 && links.isEmpty ? Color.orange : Color.pink)
                    .frame(width: 34, height: 34)
                    .background((count == 0 && links.isEmpty ? Color.orange : Color.pink).opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(count == 0 ? 0 : entries.count)).font(.body.weight(.medium))
                    Text(subtitle(count, links)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.ticketUploads > 0 { ProgressView().controlSize(.small) }
            }
            if count > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                            Button { viewing = ViewingTicket(index: position) } label: {
                                TicketCard(entry: entry, label: label(entry, position, entries))
                            }
                            .buttonStyle(TicketPressStyle())
                            .help("Toon groot, om te scannen")
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
            }
            if !links.isEmpty {
                HStack(spacing: 8) {
                    ForEach(links, id: \.label) { link in
                        Button {
                            if let url = link.webURL { NSWorkspace.shared.open(url) }
                        } label: {
                            Label(link.label, systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                        .help(link.url)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .task(id: outing.tickets.map(\.id)) {
            for ticket in outing.tickets where previews[ticket.id] == nil {
                if let preview = await TicketPreviews.load(ticket, in: outing.id, model: model) {
                    previews[ticket.id] = preview
                }
            }
        }
        .sheet(item: $viewing) { start in
            TicketViewer(outing: outing, entries: entries, labels: entries.indices.map { label(entries[$0], $0, entries) }, index: start.index)
        }
    }

    /// The holder's name, or "Kaartje 2/3" counted over every card.
    private func label(_ entry: TicketEntry, _ position: Int, _ entries: [TicketEntry]) -> String {
        entry.ticket.holder ?? (entries.count == 1 ? "Kaartje" : "Kaartje \(position + 1)/\(entries.count)")
    }

    private func title(_ count: Int) -> String {
        if count > 0 { return "\(count) \(count == 1 ? "kaartje" : "kaartjes") bewaard" }
        return outing.shopSentence ?? "Nog geen kaarten"
    }

    private func subtitle(_ count: Int, _ links: [OutingTicketLink]) -> String {
        if count > 0 { return "Klik op een kaartje om de code groot te tonen" }
        if !links.isEmpty { return "Open de pagina om ze te tonen, of sleep een kaart hierheen" }
        return "Sleep ze hierheen (pdf, Wallet-pas of screenshot)"
    }
}

private struct ViewingTicket: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct TicketPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: A card

/// A rounded ticket with a notch on each side, where Wallet tears it.
struct TicketShape: Shape {
    var notchY: CGFloat
    var radius: CGFloat = 14
    var notch: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: radius)
        path.addEllipse(in: CGRect(x: rect.minX - notch, y: rect.minY + notchY - notch, width: notch * 2, height: notch * 2))
        path.addEllipse(in: CGRect(x: rect.maxX - notch, y: rect.minY + notchY - notch, width: notch * 2, height: notch * 2))
        return path
    }
}

private struct TicketCard: View {
    @Environment(\.colorScheme) private var scheme
    let entry: TicketEntry
    let label: String

    static let size = CGSize(width: 150, height: 206)
    static let footer: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            face.frame(height: Self.size.height - Self.footer).clipped()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(scheme == .dark ? Color(white: 0.17) : .white)
        .clipShape(TicketShape(notchY: Self.size.height - Self.footer), style: FillStyle(eoFill: true))
        .overlay(alignment: .bottom) {
            Line()
                .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 1)
                .padding(.horizontal, 12)
                .offset(y: -Self.footer)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.14), radius: 6, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var face: some View {
        switch entry.face {
        case let .pass(pass, code):
            PassFace(pass: pass, code: code, codeSide: 92, compact: true)
        case let .code(code):
            Color.white.overlay { CodeView(code: code, side: 104) }
        case .file:
            Color.secondary.opacity(0.1).overlay {
                VStack(spacing: 6) {
                    Image(systemName: entry.ticket.contentType == "application/pdf" ? "doc.richtext" : "photo")
                        .font(.system(size: 30, weight: .light))
                    Text("Geen code gevonden").font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        case .loading:
            Color.secondary.opacity(0.1).overlay { ProgressView().controlSize(.small) }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.callout.weight(.semibold)).lineLimit(1)
                Text(entry.ticket.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if entry.ticket.personalised {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("Op naam gezet")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.footer)
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}

/// A Wallet pass in its own colours with its code on white.
private struct PassFace: View {
    let pass: TicketPass
    let code: CGImage?
    let codeSide: CGFloat
    var compact = false

    var body: some View {
        let foreground = pass.foreground?.color ?? .white
        VStack(spacing: compact ? 6 : 14) {
            VStack(spacing: 1) {
                if let organisation = pass.organisation {
                    Text(organisation.uppercased())
                        .font(compact ? .system(size: 9, weight: .semibold) : .caption.weight(.semibold))
                        .tracking(0.6)
                        .opacity(0.8)
                        .lineLimit(1)
                }
                if let title = pass.title {
                    Text(title).font(compact ? .caption.weight(.bold) : .title2.weight(.bold)).lineLimit(compact ? 1 : 2)
                }
            }
            .multilineTextAlignment(.center)
            if !compact, !pass.fields.isEmpty {
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
                if !compact, let alt = barcode.altText {
                    Text(alt).font(.callout.monospaced()).opacity(0.85)
                }
            }
        }
        .foregroundStyle(foreground)
        .padding(compact ? 10 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pass.background?.color ?? Color(red: 0.55, green: 0.12, blue: 0.32))
    }
}

extension PassBarcode.Format {
    var kind: TicketCode.Kind {
        switch self {
        case .qr: .qr
        case .pdf417: .pdf417
        case .aztec: .aztec
        case .code128: .code128
        }
    }
}

/// A code on white with a quiet zone around it; a redrawn code is scaled
/// module by module, never smoothed, so a scanner reads it from the screen.
private struct CodeView: View {
    let code: TicketCode
    let side: CGFloat

    var body: some View {
        Image(decorative: code.image, scale: 1)
            .interpolation(code.crisp ? .none : .high)
            .resizable()
            .aspectRatio(CGFloat(code.image.width) / CGFloat(code.image.height), contentMode: .fit)
            .frame(maxWidth: code.isSquare ? side : side * 2.4, maxHeight: code.isSquare ? side : side * 0.9)
            .padding(side * 0.08)
            .background(.white)
    }
}

// MARK: Big, for the door

private struct TicketViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let outing: Outing
    let entries: [TicketEntry]
    let labels: [String]
    @State var index: Int

    private var entry: TicketEntry? { entries.indices.contains(index) ? entries[index] : nil }

    var body: some View {
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
                Button { _ = step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                    .accessibilityLabel("Vorige")
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(labels.indices.contains(index) ? labels[index] : "Kaartje").font(.headline)
                Text([outing.title, entry?.ticket.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if entries.count > 1 {
                Button { _ = step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index >= entries.count - 1)
                    .accessibilityLabel("Volgende")
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

    @ViewBuilder
    private var content: some View {
        switch entry?.face {
        case let .pass(pass, code):
            PassFace(pass: pass, code: code, codeSide: 300)
        case let .code(code):
            Color.white.overlay { CodeView(code: code, side: 380) }
        case .file, nil:
            ContentUnavailableView("Geen code gevonden", systemImage: "ticket", description: Text("Open het bestand om de kaart te tonen."))
        case .loading:
            ProgressView()
        }
    }

    private func step(_ by: Int) -> KeyPress.Result {
        let next = index + by
        guard entries.indices.contains(next) else { return .ignored }
        index = next
        return .handled
    }
}
