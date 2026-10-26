import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

/// A poster on the wall: the picture, a sticker with the year, a stamp for
/// what the household decided, and the title in poster letters. A click
/// opens the scrapbook; the keyboard cursor lifts it like the mouse does.
struct PosterCard: View {
    @Environment(LumosModel.self) private var model
    let title: TitleSummary
    let card: CardID
    var width: CGFloat = 132
    var angle: Double = 0
    @State private var hovering = false

    private var height: CGFloat { (width * 1.45).rounded() }
    private var isCursor: Bool { model.cursor == card && model.focus == .content }
    private var isOpen: Bool { model.inspected == title.ref }
    private var lifted: Bool { hovering || isCursor }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(title: title, style: .poster, maxPixels: Int(width * 2.4), placeholderTitle: false)
                .frame(width: width, height: height)
                .grayscale(title.pass == nil ? 0 : 0.8)
                .opacity(title.pass == nil ? 1 : 0.5)
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .init(x: 0.5, y: 0.45), endPoint: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                Text(line)
                    .font(.round(9.5, .bold))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Text(title.title)
                    .poster(width > 150 ? 23 : 19)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 11)
            .frame(width: width, alignment: .leading)
            overlays
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .overlay {
            RoundedRectangle(cornerRadius: 19)
                .strokeBorder(Palette.lemon, lineWidth: isCursor ? 3 : isOpen ? 2 : 0)
                .padding(-4)
        }
        .shadow(color: .black.opacity(lifted ? 0.55 : 0.4), radius: lifted ? 24 : 14, y: lifted ? 16 : 10)
        .rotationEffect(.degrees(lifted ? 0 : angle))
        .offset(y: lifted ? -16 : 0)
        .scaleEffect(lifted ? 1.06 : 1)
        .zIndex(lifted ? 10 : 0)
        .animation(.spring(duration: 0.32, bounce: 0.3), value: lifted)
        .contentShape(Rectangle())
        .id(card.description)
        .onHover { hovering = $0 }
        .onTapGesture {
            model.select(card)
            model.open(title.ref, from: card, focusInside: false)
        }
        .contextMenu { CardMenu(title: title, card: card) }
        .popover(isPresented: Binding(
            get: { model.reasonMenu == title.ref && model.cursor == card && model.focus != .inspector },
            set: { if !$0 { model.reasonMenu = nil } }
        ), arrowEdge: .bottom) {
            ReasonSheet(ref: title.ref)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var line: String {
        [title.kind, title.year.map(String.init), title.length].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var parts = [title.title, title.kind.lowercased(), title.line]
        if title.availability == .available { parts.append("in Jellyfin") }
        if title.onList { parts.append(model.scope == .shared ? "op onze lijst" : "op jouw lijst") }
        if let pass = title.pass { parts.append("overgeslagen\(pass.reason.map { ": \($0)" } ?? "")") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var overlays: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if let year = title.year {
                    Sticker(size: width > 150 ? 52 : 44, angle: -8) {
                        VStack(spacing: -1) {
                            Text(title.mediaType == .tv ? "serie" : "film").font(.round(8, .bold)).textCase(.uppercase)
                            Text(String(year)).font(.round(width > 150 ? 15 : 13, .black))
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.top, 8)
                }
                Spacer()
                if let stamp {
                    Stamp(text: stamp.0, colour: stamp.1, angle: 10, size: width > 150 ? 13 : 11)
                        .padding(.trailing, 6)
                        .padding(.top, 14)
                }
            }
            Spacer()
            HStack(alignment: .bottom) {
                if title.hasTrailer {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(0.9)))
                        .help("Trailer, speelt pas na een klik (T)")
                }
                if model.scope == .shared, title.onMine, !title.onShared {
                    Text("jouw lijst").pill(Palette.candy, Color(hex: 0x5A1C3A), height: 18).font(.round(9, .bold))
                        .help("Staat op jouw eigen lijst, samen nog niet")
                }
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
            .padding(8)
        }
    }

    /// One stamp says the most important thing: on the list, skipped, or already in Jellyfin.
    private var stamp: (String, Color)? {
        if title.onList { return ("Op de lijst", Palette.mint) }
        if let pass = title.pass { return (pass.kind == .seen ? "Al gezien" : "Niet nu", Palette.lilac) }
        if title.availability == .available { return ("In Jellyfin", Palette.sky) }
        return nil
    }
}

struct QuickButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Palette.ink)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.94)))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Right-click on a poster.
struct CardMenu: View {
    @Environment(LumosModel.self) private var model
    let title: TitleSummary
    let card: CardID

    var body: some View {
        let list = model.scope == .shared ? "onze lijst" : "jouw lijst"
        Button("Plakboek openen") {
            model.select(card)
            model.open(title.ref, from: card, focusInside: true)
        }
        Button(title.onList ? "Van \(list) halen" : "Op \(list) zetten") { Task { await model.toggleList(title.ref) } }
            .accessibilityIdentifier("hogsmeade.approve.list")
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

/// "Niet nu" with an optional reason, as a stack of stickers: Enter takes
/// none, arrows pick one. The model holds the choice, like in Lumos.
struct ReasonSheet: View {
    @Environment(LumosModel.self) private var model
    let ref: TitleRef

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Niet nu. Waarom, als je wilt?")
                .font(.round(12, .bold))
                .foregroundStyle(Palette.mutedOnNight)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            ForEach(Array(LumosModel.reasonOptions.enumerated()), id: \.offset) { index, option in
                let on = index == model.reasonChoice
                Button {
                    Task { await model.chooseReason(index) }
                } label: {
                    HStack {
                        Text(option)
                        Spacer()
                        if index == 0 { Text("⏎").font(.round(11, .bold)).opacity(0.6) }
                    }
                    .font(.round(13, on ? .heavy : .semibold))
                    .foregroundStyle(on ? Palette.onLemon : .white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(on ? Palette.lemon : .white.opacity(0.1)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 240)
        .background(Palette.night)
    }
}
