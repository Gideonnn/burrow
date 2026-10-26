import BurrowUI
import HogsmeadeCore
import HogsmeadeUI
import SwiftUI

/// The day itself: the outing takes the screen. Confetti, a clock that
/// counts to the doors, the tickets as stubs and the route in a glass card.
struct TonightScreen: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    var showWall: () -> Void
    @State private var viewing: ViewingTicket?

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [.init(color: Color(hex: 0x3D1B8C), location: 0), .init(color: Color(hex: 0x8A3FD1), location: 0.4), .init(color: Color(hex: 0xE0589A), location: 0.75), .init(color: Color(hex: 0xF7B389), location: 1)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            ConfettiBurst(trigger: nil, continuous: true).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(outing.dayWord() + "!")
                        .font(.round(34, .black)).foregroundStyle(Palette.onLemon)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.lemon))
                        .rotationEffect(.degrees(-6))
                        .shadow(color: .black.opacity(0.25), radius: 14, y: 10)
                        .padding(.top, 40).padding(.leading, 54)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 12) {
                        Text(company).font(.round(15, .bold)).foregroundStyle(.white.opacity(0.8)).rotationEffect(.degrees(4))
                        Button(action: showWall) {
                            Label("Alle uitjes", systemImage: "rectangle.split.2x1").pill(.black.opacity(0.25), .white, height: 36)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 48).padding(.trailing, 60)
                }
                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 14) {
                        Button { model.open(outing.id) } label: {
                            Text(outing.title).poster(100).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.5)
                                .multilineTextAlignment(.leading).shadow(color: .black.opacity(0.25), radius: 40, y: 10)
                        }
                        .buttonStyle(.plain)
                        HStack(spacing: 18) {
                            if let doors = outing.doorsAt { Label("Deuren \(OutingFormat.time(doors))", systemImage: "clock") }
                            else if !outing.allDay { Label(OutingFormat.time(outing.startsAt), systemImage: "clock") }
                            if let first = OutingFormat.whereLines(outing).first {
                                Label([first, outing.city].compactMap { $0 }.joined(separator: ", "), systemImage: "mappin.and.ellipse")
                            }
                            if let who = OutingsModel.sentence(model.others(on: outing)) { Label("met \(who)", systemImage: "heart") }
                        }
                        .font(.round(20, .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                        Clock(target: outing.doorsAt ?? outing.startsAt, label: outing.doorsAt != nil ? "Deuren over" : "Begint over")
                    }
                    .padding(.leading, 60)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 14) {
                        RouteCard(outing: outing)
                        chips
                    }
                    .padding(.trailing, 54)
                }
                .padding(.top, 10)
                Spacer()
                stubs.padding(.leading, 60).padding(.bottom, 36)
            }
        }
    }

    private var company: String {
        let n = outing.attendees.count
        return n == 2 ? "veel plezier, jullie twee" : n > 2 ? "veel plezier, met z'n \(n == 3 ? "drieën" : n == 4 ? "vieren" : "\(n)")" : "veel plezier"
    }

    /// What is done and what the mails say, as chips.
    private var chips: some View {
        FlowLayout(spacing: 8) {
            ForEach(outing.checklist.filter(\.done)) { task in
                Label(task.title, systemImage: "checkmark").pill(Palette.mint.opacity(0.9), Palette.onMint, height: 36)
            }
            ForEach(outing.openItems().map(\.task)) { task in
                Label(task.title, systemImage: "circle").pill(.white.opacity(0.18), .white, height: 36)
            }
            if !outing.mails.isEmpty {
                Label(outing.mails.count == 1 ? "1 mail" : "\(outing.mails.count) mails", systemImage: "envelope").pill(.white.opacity(0.18), .white, height: 36)
            }
        }
        .frame(maxWidth: 380, alignment: .trailing)
    }

    private var stubs: some View {
        TicketEntriesReader(outing: outing) { entries in
            VStack(alignment: .leading, spacing: 10) {
                if entries.isEmpty {
                    Button { model.open(outing.id) } label: {
                        Label(outing.shopSentence ?? "Nog geen kaartjes; zet ze in het plakboek", systemImage: "ticket").pill(.black.opacity(0.25), .white, height: 36)
                    }
                    .buttonStyle(.plain)
                } else {
                    Label(entries.count == 1 ? "Kaartje staat klaar" : "\(entries.count) kaartjes staan klaar", systemImage: "checkmark.circle.fill")
                        .font(.round(13, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(.black.opacity(0.25)))
                    ZStack(alignment: .leading) {
                        ForEach(Array(entries.prefix(4).enumerated()), id: \.element.id) { index, entry in
                            Button { viewing = ViewingTicket(index: index) } label: {
                                Stub(outing: outing, entry: entry, label: TicketEntry.label(entry, index, of: entries.count))
                            }
                            .buttonStyle(.plain)
                            .rotationEffect(.degrees(index % 2 == 0 ? -5 : 3))
                            .offset(x: CGFloat(index) * 110, y: CGFloat(index) * 18)
                            .zIndex(Double(index))
                        }
                    }
                    .frame(height: 118 + CGFloat(min(entries.count, 4) - 1) * 18 + 20, alignment: .topLeading)
                }
            }
            .sheet(item: $viewing) { start in TicketViewer(outing: outing, entries: entries, index: start.index) }
        }
    }
}

/// A countdown that really ticks.
struct Clock: View {
    let target: Date
    let label: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = Int(target.timeIntervalSince(context.date).rounded(.down))
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(left > 0 ? label : "Open").font(.round(14, .bold)).foregroundStyle(.white.opacity(0.8))
                if left > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(left / 3600)").font(.round(44, .black)).monospacedDigit()
                        Text("u").font(.round(18, .bold)).foregroundStyle(Palette.lemon).padding(.trailing, 6)
                        Text(String(format: "%02d", left % 3600 / 60)).font(.round(44, .black)).monospacedDigit()
                        Text("m").font(.round(18, .bold)).foregroundStyle(Palette.lemon).padding(.trailing, 6)
                        Text(String(format: "%02d", left % 60)).font(.round(44, .black)).monospacedDigit()
                        Text("s").font(.round(18, .bold)).foregroundStyle(Palette.lemon)
                    }
                    .foregroundStyle(.white)
                } else {
                    Text("ga!").font(.round(44, .black)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 22).fill(.black.opacity(0.28)).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22)))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.25)))
        }
    }
}

/// A ticket as a stub: the shop and the title, the night, the holder, the code at the tear.
struct Stub: View {
    let outing: Outing
    let entry: TicketEntry
    let label: String

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text([outing.vendor, outing.title].compactMap { $0 }.joined(separator: " · ").uppercased())
                    .font(.round(10, .bold)).kerning(1).foregroundStyle(Palette.faintOnCream).lineLimit(1)
                Text("Toegang").poster(22).foregroundStyle(Palette.ink)
                Text("\(OutingFormat.date(outing.startsAt))\(outing.doorsAt.map { " · deuren \(OutingFormat.time($0))" } ?? "")")
                    .font(.round(12, .semibold)).foregroundStyle(Color(hex: 0x4A4461)).lineLimit(1)
                HStack(spacing: 6) {
                    Avatar(label, size: 20)
                    Text(label).font(.round(12, .heavy)).foregroundStyle(Palette.ink)
                }
                .padding(.top, 4)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                Color(hex: 0xF6F2FB)
                TicketCodeFace(entry: entry, side: 50).frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(width: 86)
            .overlay(alignment: .leading) {
                Rectangle().fill(.clear).frame(width: 2).overlay(
                    VStack(spacing: 3) { ForEach(0..<20, id: \.self) { _ in Rectangle().fill(Color(hex: 0xD9D2E6)).frame(width: 2, height: 3) } })
            }
        }
        .frame(width: 300, height: 118)
        .background(.white)
        .clipShape(TicketShape(notchY: 59, radius: 14, notch: 8), style: FillStyle(eoFill: true))
        .shadow(color: .black.opacity(0.35), radius: 22, y: 14)
    }
}

/// The route in a glass card: the map, the travel time, Rijden.
struct RouteCard: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing

    var body: some View {
        PlaceReader(outing: outing) { place, lookingUp in
            if let place {
                ZStack(alignment: .bottomLeading) {
                    MapSnapshot(outing: outing, place: place, dark: true, pinTint: Palette.hot)
                    LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .bottom, endPoint: .center).allowsHitTesting(false)
                    Text("ROUTE").font(.round(12, .bold)).kerning(1.2).foregroundStyle(Palette.mutedOnNight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(18).allowsHitTesting(false)
                    HStack(alignment: .bottom) {
                        TravelTimeReader(outing: outing, place: place) { travel in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(travel?.replacingOccurrences(of: "ca. ", with: "").replacingOccurrences(of: " met de auto", with: "") ?? outing.placeLabel(place).title)
                                    .font(.round(30, .black)).foregroundStyle(.white)
                                Text(travel != nil ? "met de auto, vanaf hier" : (outing.placeLabel(place).subtitle ?? "")).font(.round(13, .semibold)).foregroundStyle(Palette.mutedOnNight)
                            }
                        }
                        Spacer()
                        Button { OutingMaps.openRoute(to: place, name: outing.placeLabel(place).title) } label: {
                            Label("Rijden", systemImage: "car.fill").pill(Palette.lemon, Palette.onLemon, height: 40).font(.round(14, .heavy))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(18)
                }
                .frame(width: 380, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.2)))
                .rotationEffect(.degrees(2))
                .shadow(color: .black.opacity(0.4), radius: 30, y: 15)
            } else if lookingUp {
                RoundedRectangle(cornerRadius: 24).fill(.black.opacity(0.2)).frame(width: 380, height: 300).rotationEffect(.degrees(2))
            }
        }
    }
}
