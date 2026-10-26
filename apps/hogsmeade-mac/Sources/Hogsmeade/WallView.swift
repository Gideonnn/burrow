import BurrowUI
import HogsmeadeCore
import HogsmeadeUI
import SwiftUI

/// The poster wall: tonight's outing as a banner on top, then everything
/// that comes, each with one sentence.
struct WallView: View {
    @Environment(OutingsModel.self) private var model

    var body: some View {
        let shown = model.shown
        let tonight = model.page == .upcoming && model.filter == nil && model.query.isEmpty ? model.today : nil
        let rest = tonight.map { today in shown.filter { $0.id != today.id } } ?? shown
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let tonight {
                    TonightBanner(outing: tonight)
                        .padding(.bottom, 24)
                }
                if !rest.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(heading(tonight: tonight != nil)).font(.system(size: 18, weight: .bold, design: .rounded))
                        Text(rest.count == 1 ? "1 uitje" : "\(rest.count) uitjes").foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, 12)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)], spacing: 16) {
                        ForEach(rest) { outing in
                            PosterCard(outing: outing, past: model.page == .past)
                        }
                    }
                } else if tonight == nil {
                    empty
                }
            }
            .padding(EdgeInsets(top: 22, leading: 26, bottom: 30, trailing: 26))
        }
        .background(BurrowColor.plaster)
    }

    private func heading(tonight: Bool) -> String {
        if model.page == .past { return "Geweest" }
        if !model.query.isEmpty { return "Gevonden" }
        if tonight { return "Daarna" }
        if case .person(let id) = model.filter, let person = model.people.first(where: { $0.id == id }) { return "Waar \(person.name) heen gaat" }
        if case .kind = model.filter { return model.kinds.first { .kind($0.key) == model.filter }?.label ?? "Binnenkort" }
        return "Binnenkort"
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(model.page == .past ? "Nog niets geweest" : "Nog geen uitjes", systemImage: "ticket")
        } description: {
            Text(model.query.isEmpty
                ? "Hedwig hangt ze hier op zodra een bestelmail binnenkomt, of voeg er zelf een toe."
                : "Niets gevonden voor “\(model.query)”.")
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

/// Tonight: the gradient with a few confetti dots, the facts and the two
/// buttons that matter on the day.
struct TonightBanner: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    @State private var viewing: ViewingTicket?

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(outing.dayWord().uppercased()) IS HET ZOVER")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).tracking(1).opacity(0.9)
                Text(outing.title)
                    .font(.system(size: 32, weight: .heavy, design: .rounded)).lineLimit(2)
                HStack(spacing: 16) {
                    if let times = OutingFormat.times(outing) ?? (outing.allDay ? nil : OutingFormat.time(outing.startsAt)) {
                        Label(times, systemImage: "clock")
                    }
                    if let first = OutingFormat.whereLines(outing).first {
                        Label([first, outing.city].compactMap { $0 }.joined(separator: ", "), systemImage: "mappin.and.ellipse")
                    }
                    if let who = OutingsModel.sentence(outing.attendees.map(\.name)) { Text(who) }
                }
                .font(.system(size: 14)).opacity(0.95).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                TicketEntriesReader(outing: outing) { entries in
                    Button {
                        if entries.isEmpty { model.open(outing.id) } else { viewing = ViewingTicket(index: 0) }
                    } label: {
                        Label(entries.isEmpty ? "Kaartjes" : (entries.count == 1 ? "Kaartje" : "\(entries.count) kaartjes"), systemImage: "ticket")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BannerButton(filled: true))
                    .sheet(item: $viewing) { start in TicketViewer(outing: outing, entries: entries, index: start.index) }
                }
                PlaceReader(outing: outing) { place, _ in
                    if let place {
                        TravelTimeReader(outing: outing, place: place) { travel in
                            Button {
                                OutingMaps.openRoute(to: place, name: outing.placeLabel(place).title)
                            } label: {
                                Label(travel.map { "Route · \($0.replacingOccurrences(of: "ca. ", with: "").replacingOccurrences(of: " met de auto", with: ""))" } ?? "Route", systemImage: "arrow.triangle.turn.up.right.diamond")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(BannerButton(filled: false))
                        }
                    }
                }
            }
            .frame(width: 170)
        }
        .foregroundStyle(.white)
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        .background {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x5B2AA8), Color(hex: 0x8A3FD1), Color(hex: 0xE0589A)], startPoint: .leading, endPoint: .trailing)
                ConfettiDots()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { model.open(outing.id) }
    }
}

/// A few still confetti pieces, as in the design.
private struct ConfettiDots: View {
    var body: some View {
        GeometryReader { geo in
            let spots: [(x: Double, y: Double, c: Color, r: Double, s: Double)] = [
                (0.52, 0.14, Palette.lemon, 20, 8), (0.58, 0.70, Palette.mint, -30, 8), (0.66, 0.30, Palette.sky, 45, 8),
                (0.48, 0.80, Palette.peach, 10, 8), (0.72, 0.78, Palette.candy, 60, 8), (0.62, 0.50, .white, 0, 5),
                (0.40, 0.30, Palette.lemon, -15, 6), (0.76, 0.20, .white, 30, 5),
            ]
            ForEach(Array(spots.enumerated()), id: \.offset) { _, spot in
                RoundedRectangle(cornerRadius: 2).fill(spot.c)
                    .frame(width: spot.s, height: spot.s)
                    .rotationEffect(.degrees(spot.r))
                    .position(x: geo.size.width * spot.x, y: geo.size.height * spot.y)
                    .opacity(0.85)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct BannerButton: ButtonStyle {
    var filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .foregroundStyle(filled ? Color(hex: 0x5B2AA8) : .white)
            .background(filled ? Color.white : Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(filled ? 0 : 0.35)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// One poster: the picture with the date and the nights left, the title,
/// kind and place, the status chip and who goes.
struct PosterCard: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    var past = false
    @State private var hovering = false

    var body: some View {
        Button { model.open(outing.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                art
                VStack(alignment: .leading, spacing: 2) {
                    Text(outing.title).font(.system(size: 15, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    HStack(alignment: .center) {
                        StatusChip(status: outing.status(now: model.now()), past: past)
                        Spacer(minLength: 4)
                        if !past {
                            HStack(spacing: -5) {
                                ForEach(outing.attendees, id: \.id) { person in
                                    Avatar(person.name, size: 20).overlay(Circle().strokeBorder(BurrowColor.paper, lineWidth: 2))
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
            }
            .background(BurrowColor.paper)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(hovering ? 0.14 : 0.08), radius: hovering ? 8 : 2, y: hovering ? 4 : 1)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.black.opacity(0.05)))
            .scaleEffect(hovering ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: hovering)
        .accessibilityLabel("\(outing.title), \(OutingFormat.when(outing))")
    }

    private var subtitle: String {
        past ? "Geweest · \(OutingFormat.date(outing.startsAt))" : outing.kindAndVenue.nilIfEmptyText ?? OutingFormat.when(outing)
    }

    private var art: some View {
        OutingPoster(outing: outing, symbolSize: 36, past: past)
            .frame(height: 128)
            .overlay(alignment: .topLeading) { DateTile(date: outing.startsAt).padding(10) }
            .overlay(alignment: .topTrailing) {
                if outing.image == nil {
                    Image(systemName: outing.kindSymbol).font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.9)).padding(14)
                        .opacity(0)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !past {
                    Text(model.nightsLabel(outing))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x1F1C18))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(.white.opacity(0.92), in: Capsule())
                        .padding(10)
                }
            }
    }
}

/// "Alles geregeld", "Nog doen: …", in its colour.
struct StatusChip: View {
    let status: OutingStatus
    var past = false

    var body: some View {
        HStack(spacing: 5) {
            if status.tone == .done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
            Text(past ? "Was het leuk?" : status.text).lineLimit(1)
        }
        .font(.system(size: 12, weight: status.tone == .later || past ? .regular : .medium))
        .foregroundStyle(colour)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(colour.opacity(0.12), in: Capsule())
    }

    private var colour: Color {
        if past { return BurrowColor.secondaryText }
        switch status.tone {
        case .done: return BurrowColor.success
        case .todo: return BurrowColor.warning
        case .today: return BurrowColor.hogsmeade
        case .later, .past: return BurrowColor.secondaryText
        }
    }
}

extension String {
    var nilIfEmptyText: String? { isEmpty ? nil : self }
}
