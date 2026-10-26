import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

/// A still or poster with its title. A click selects it and opens the
/// details; the keyboard cursor draws the ring.
struct CardView: View {
    @Environment(LumosModel.self) private var model
    let title: TitleSummary
    let card: CardID
    let style: TitleRow.Style
    @State private var hovering = false

    private var size: CGSize {
        style == .wide ? CGSize(width: 250, height: 140.6) : CGSize(width: 124, height: 186)
    }

    private var isCursor: Bool { model.cursor == card && model.focus == .content }
    private var isOpen: Bool { model.inspected == title.ref }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack {
                Artwork(title: title, style: style)
                    .frame(width: size.width, height: size.height)
                    .grayscale(title.pass == nil ? 0 : 0.7)
                    .opacity(title.pass == nil ? 1 : 0.55)
                overlays
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.1), radius: hovering ? 10 : 4, y: hovering ? 5 : 2)
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(BurrowColor.lumos, lineWidth: isCursor ? 3 : isOpen ? 2 : 0)
                    .padding(-3)
            }
            .offset(y: hovering ? -2 : 0)
            .padding(.bottom, 5)
            Text(title.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Text(title.match ?? title.line)
                .font(.system(size: 11))
                .foregroundStyle(title.match == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(BurrowColor.lumos))
                .lineLimit(1)
        }
        .frame(width: size.width, alignment: .leading)
        .contentShape(Rectangle())
        .id(card.description)
        .onHover { inside in
            hovering = inside
            if inside { model.prefetch(title.ref) }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture {
            model.select(card)
            model.open(title.ref, from: card, focusInside: false)
        }
        .contextMenu { CardMenu(title: title, card: card) }
        .popover(isPresented: Binding(
            get: { model.reasonMenu == title.ref && model.cursor == card && model.focus != .inspector },
            set: { if !$0 { model.reasonMenu = nil } }
        ), arrowEdge: .bottom) {
            ReasonMenu(ref: title.ref)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = [title.title, title.kind.lowercased(), title.line]
        if title.availability == .available { parts.append("in Jellyfin") }
        if title.onList { parts.append(model.scope == .shared ? "op onze lijst" : "op jouw lijst") }
        if let pass = title.pass { parts.append("overgeslagen\(pass.reason.map { ": \($0)" } ?? "")") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var overlays: some View {
        VStack {
            HStack(spacing: 4) {
                if style == .wide {
                    if title.availability == .available { Badge(text: "In Jellyfin", dot: true) }
                    if title.hasTrailer { Badge(text: "Trailer", symbol: "play.fill") }
                }
                if model.scope == .shared, title.onMine, !title.onShared {
                    Badge(text: "Op jouw lijst", symbol: "person.fill")
                }
                Spacer()
                if title.onList {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(BurrowColor.lumos))
                        .help(model.scope == .shared ? "Op onze lijst" : "Op jouw lijst")
                }
            }
            Spacer()
            HStack {
                Spacer()
                if hovering {
                    QuickButton(symbol: title.onList ? "checkmark" : "plus", help: title.onList ? "Van de lijst halen (J)" : "Op de lijst (J)") {
                        model.select(card)
                        Task { await model.toggleList(title.ref) }
                    }
                    QuickButton(symbol: "xmark", help: "Niet nu, reden optioneel (N)") {
                        model.select(card)
                        model.reasonMenu = title.ref
                    }
                }
            }
        }
        .padding(7)
    }
}

struct Badge: View {
    let text: String
    var symbol: String?
    var dot = false

    var body: some View {
        HStack(spacing: 4) {
            if dot { Circle().fill(Color(red: 0.43, green: 0.86, blue: 0.61)).frame(width: 6, height: 6) }
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct QuickButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(white: 0.12))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.92)))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Right-click on a card.
struct CardMenu: View {
    @Environment(LumosModel.self) private var model
    let title: TitleSummary
    let card: CardID

    var body: some View {
        let list = model.scope == .shared ? "onze lijst" : "jouw lijst"
        Button("Details tonen") {
            model.select(card)
            model.open(title.ref, from: card, focusInside: true)
        }
        Button(title.onList ? "Van \(list) halen" : "Op \(list) zetten") { Task { await model.toggleList(title.ref) } }
            .accessibilityIdentifier("lumos.approve.list")
        if title.hasTrailer {
            Button("Trailer afspelen") {
                model.select(card)
                Task { await model.playTrailer(title.ref) }
            }
        }
        Divider()
        Menu("Niet nu") {
            Button("Zonder reden") { Task { await model.notNow(title.ref) } }
            ForEach(LumosModel.passReasons, id: \.self) { reason in
                Button(reason) { Task { await model.notNow(title.ref, reason: reason) } }
            }
        }
        Button("Al gezien") { Task { await model.seen(title.ref) } }
    }
}

/// "Niet nu" with an optional reason: Enter takes none, arrows pick one.
/// The keys stay with the rows or the inspector; the model holds the choice.
struct ReasonMenu: View {
    @Environment(LumosModel.self) private var model
    let ref: TitleRef

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Niet nu, reden is optioneel").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
            ForEach(Array(LumosModel.reasonOptions.enumerated()), id: \.offset) { index, option in
                let on = index == model.reasonChoice
                Button {
                    Task { await model.chooseReason(index) }
                } label: {
                    Text(option)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .foregroundStyle(on ? .white : .primary)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? BurrowColor.lumos : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 230)
    }
}

