import BurrowUI
import HogsmeadeCore
import HogsmeadeUI
import SwiftUI

/// The wall: a greeting that counts the nights to the next outing, the
/// posters as a hand of cards, and the ride (a line with a dot per outing).
struct WallScreen: View {
    @Environment(OutingsModel.self) private var model
    var searchFocused: FocusState<Bool>.Binding
    var tonightHidden: Bool
    var showTonight: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Orbs().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    if model.query.isEmpty, model.filter == nil, let next = model.next {
                        Hello(outing: next)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.query.isEmpty ? "Binnenkort" : "Gevonden").font(.round(56, .black)).foregroundStyle(.white)
                            Text(model.query.isEmpty ? "Alles wat eraan komt." : "Voor “\(model.query)”.").font(.round(17, .medium)).foregroundStyle(Palette.mutedOnNight)
                        }
                        .padding(.top, 50)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        TopBar(searchFocused: searchFocused)
                        if tonightHidden {
                            Button(action: showTonight) {
                                Label("Terug naar vanavond", systemImage: "sparkles").pill(Palette.lemon, Palette.onLemon, height: 34)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 64, bottom: 0, trailing: 22))
                Spacer(minLength: 10)
                Hand(outings: model.shown)
                    .frame(height: 300)
                Spacer(minLength: 10)
                if model.query.isEmpty { Ride(outings: model.upcoming).padding(.horizontal, 64) }
                Spacer().frame(height: 90)
            }
        }
        .background(Palette.night.ignoresSafeArea())
        .overlay {
            if model.shown.isEmpty && !model.isLoading {
                Text(model.query.isEmpty ? "Nog niets aan de wand. Hedwig hangt een uitje op zodra een bestelmail binnenkomt, of druk op +." : "Niets gevonden.")
                    .font(.round(17, .medium)).foregroundStyle(Palette.mutedOnNight).multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
        }
    }
}

/// "HÉ GIDEON. Nog 3 nachtjes tot Neon Nineties in De Kolenloods, samen met Eva."
struct Hello: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing

    var body: some View {
        let n = model.nights(until: outing)
        VStack(alignment: .leading, spacing: 6) {
            Text("HÉ \(model.myName.uppercased())").font(.round(15, .bold)).foregroundStyle(Palette.lemon).kerning(0.6)
            Group {
                if n == 0 {
                    Text(outing.dayWord() + "!").font(.round(84, .black)).foregroundStyle(.white)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        Text("Nog").font(.round(84, .black)).foregroundStyle(.white)
                        Shimmer(text: String(n)).font(.round(84, .black))
                        Text(n == 1 ? "nachtje" : "nachtjes").font(.round(84, .black)).foregroundStyle(.white)
                    }
                }
            }
            .lineLimit(1).minimumScaleFactor(0.5)
            (Text("tot ") + Text(outing.title).foregroundStyle(.white).bold() + Text(place) + Text(company))
                .font(.round(18, .medium)).foregroundStyle(Palette.mutedOnNight).lineLimit(2)
            cta
        }
        .padding(.top, 50)
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var place: String { outing.venue.map { " in \($0)" } ?? "" }

    private var company: String {
        OutingsModel.sentence(model.others(on: outing)).map { ", samen met \($0)." } ?? "."
    }

    @ViewBuilder private var cta: some View {
        let stamp = outing.wallStamp()
        Button { model.open(outing.id) } label: {
            switch stamp.tone {
            case .ok:
                Label("Alles staat klaar", systemImage: "checkmark").pill(Palette.mint, Palette.onMint, height: 40).font(.round(14, .heavy))
            case .todo:
                Label("Nog doen: \(outing.openItems().first?.task.title.lowercasedFirst ?? "")", systemImage: "checklist").pill(Palette.lemon, Palette.onLemon, height: 40).font(.round(14, .heavy))
            case .tickets:
                Label("Kaartjes toevoegen", systemImage: "ticket").pill(.white, Palette.violet, height: 40).font(.round(14, .heavy))
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
    }
}

/// A number in a slowly moving gradient.
struct Shimmer: View {
    let text: String
    @State private var phase: CGFloat = 0

    var body: some View {
        Text(text)
            .foregroundStyle(
                LinearGradient(colors: [Palette.lemon, Palette.peach, Palette.candy, Palette.lemon], startPoint: UnitPoint(x: phase - 1, y: 0.5), endPoint: UnitPoint(x: phase + 1, y: 0.5)))
            .onAppear { withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { phase = 2 } }
    }
}

/// The posters fanned out like a hand of cards; the hovered one comes up.
struct Hand: View {
    @Environment(OutingsModel.self) private var model
    let outings: [Outing]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: -14) {
                ForEach(Array(outings.enumerated()), id: \.element.id) { index, outing in
                    let centre = Double(outings.count - 1) / 2
                    let distance = Double(index) - centre
                    Poster(outing: outing, angle: min(8, max(-8, distance * 3.2)), lift: abs(distance) * 7, delay: Double(index) * 0.37)
                        .zIndex(Double(index))
                }
            }
            .padding(.horizontal, 64)
            .padding(.top, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollClipDisabled()
    }
}

/// One poster in the hand: the art with stripes, a date sticker, a stamp,
/// kind and place, the title in poster letters.
struct Poster: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    var angle: Double = 0
    var lift: Double = 0
    var delay: Double = 0
    var past = false
    @State private var hovering = false
    @State private var bob = false

    var body: some View {
        Button { model.open(outing.id) } label: {
            ZStack(alignment: .bottomLeading) {
                OutingPoster(outing: outing, symbolSize: 0, stripes: true, past: past)
                if outing.image == nil {
                    Image(systemName: outing.kindSymbol).font(.system(size: 120, weight: .light)).foregroundStyle(.white.opacity(0.22))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).offset(x: 24, y: 40)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(outing.kindAndVenue.uppercased()).font(.round(11, .bold)).foregroundStyle(.white.opacity(0.75)).kerning(0.8).lineLimit(1)
                    Text(outing.title).poster(23).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
                }
                .padding(16)
            }
            .frame(width: 170, height: 246)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Sticker(colour: .white, text: Palette.ink, angle: -8) {
                    VStack(spacing: 0) {
                        Text(OutingFormat.weekday(outing.startsAt).prefix(2)).font(.round(10, .bold)).textCase(.uppercase)
                        Text(OutingFormat.day(outing.startsAt)).font(.round(22, .black))
                        Text(OutingFormat.month(outing.startsAt)).font(.round(10, .bold)).textCase(.uppercase)
                    }
                }
                .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                if past {
                    Text("Geweest").font(.round(13, .heavy)).foregroundStyle(Palette.lemon).shadow(color: .black.opacity(0.5), radius: 4).padding(14)
                } else {
                    let stamp = outing.wallStamp()
                    Stamp(stamp.text, colour: stamp.tone == .ok ? Palette.mint : stamp.tone == .todo ? Palette.lemon : .white, angle: 10, size: 15)
                        .padding(.top, 20).padding(.trailing, 10)
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.6 : 0.5), radius: hovering ? 35 : 24, y: hovering ? 30 : 20)
            .rotationEffect(.degrees(hovering ? 0 : angle))
            .offset(y: hovering ? -26 : lift + (bob ? -8 : 0))
            .scaleEffect(hovering ? 1.06 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hovering)
            .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true).delay(delay), value: bob)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear { if !past { bob = true } }
        .zIndex(hovering ? 10 : 0)
        .accessibilityLabel("\(outing.title), \(OutingFormat.when(outing))")
    }
}

/// The line from now through the coming months, a dot per outing.
struct Ride: View {
    @Environment(OutingsModel.self) private var model
    let outings: [Outing]

    var body: some View {
        let now = model.now()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = max(calendar.date(byAdding: .month, value: 8, to: start) ?? start, outings.last.map { calendar.date(byAdding: .day, value: 7, to: $0.startsAt) ?? $0.startsAt } ?? start)
        let span = max(end.timeIntervalSince(start), 1)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 3)
                    Text("nu").font(.round(11, .heavy)).foregroundStyle(Palette.lemon).offset(x: -6, y: -24)
                    ForEach(Array(outings.enumerated()), id: \.element.id) { index, outing in
                        let x = geo.size.width * min(1, outing.startsAt.timeIntervalSince(start) / span)
                        Circle().fill(index == 0 ? Palette.lemon : Palette.candy)
                            .frame(width: index == 0 ? 12 : 8, height: index == 0 ? 12 : 8)
                            .overlay(Circle().fill(Palette.lemon.opacity(index == 0 ? 0.2 : 0)).frame(width: 22, height: 22))
                            .position(x: x, y: 1.5)
                            .help(outing.title)
                    }
                }
            }
            .frame(height: 3)
            HStack {
                ForEach(months(from: start, to: end, calendar), id: \.self) { month in
                    Text(month)
                    if month != months(from: start, to: end, calendar).last { Spacer() }
                }
            }
            .font(.round(11, .bold)).foregroundStyle(Palette.dimOnNight).kerning(1).textCase(.uppercase)
        }
    }

    private func months(from start: Date, to end: Date, _ calendar: Calendar) -> [String] {
        var result: [String] = []
        var cursor = start
        while cursor < end {
            result.append(OutingFormat.month(cursor))
            cursor = calendar.date(byAdding: .month, value: 1, to: cursor) ?? end
        }
        return result
    }
}

/// Geweest: the posters a little turned, with the date.
struct PastScreen: View {
    @Environment(OutingsModel.self) private var model
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        ZStack(alignment: .topLeading) {
            Orbs().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Geweest").font(.round(56, .black)).foregroundStyle(.white)
                        Text("Herinneringen aan wat jullie deden.").font(.round(17, .medium)).foregroundStyle(Palette.mutedOnNight)
                    }
                    .padding(.top, 50)
                    Spacer()
                    TopBar(searchFocused: searchFocused)
                }
                .padding(EdgeInsets(top: 14, leading: 64, bottom: 20, trailing: 22))
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 170), spacing: 18)], alignment: .leading, spacing: 18) {
                        ForEach(Array(model.shown.enumerated()), id: \.element.id) { index, outing in
                            Poster(outing: outing, angle: index % 2 == 0 ? -1.5 : 1.5, past: true)
                        }
                    }
                    .padding(.horizontal, 64)
                    .padding(.top, 20)
                    .padding(.bottom, 100)
                }
                .scrollClipDisabled()
            }
        }
        .background(Palette.night.ignoresSafeArea())
        .overlay {
            if model.shown.isEmpty {
                Text("Nog niets geweest.").font(.round(17, .medium)).foregroundStyle(Palette.mutedOnNight)
            }
        }
    }
}

/// Nieuw uitje, as a panel over the night.
struct NewOutingPanel: View {
    @Environment(OutingsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind = ""
    @State private var venue = ""
    @State private var startsAt = NewOutingSheet.nextEvening()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nieuw uitje").font(.round(26, .black)).foregroundStyle(.white)
            Text("Meestal hoeft dit niet: Hedwig ziet de bevestigingsmail en hangt het uitje vanzelf aan de wand. Typ hier alleen iets wat nog geen mail heeft.")
                .font(.round(14, .medium)).foregroundStyle(Palette.mutedOnNight).fixedSize(horizontal: false, vertical: true)
            field("Bijvoorbeeld: Schaatsen op de Jaap Eden", $title)
            HStack(spacing: 10) {
                field("Soort: feest, theater…", $kind)
                field("Waar", $venue)
            }
            DatePicker("Wanneer", selection: $startsAt).font(.round(14, .bold)).foregroundStyle(.white)
            HStack {
                Spacer()
                Button("Laat maar") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain).pill(.white.opacity(0.1), .white, height: 36)
                Button("Hang aan de wand") {
                    Task {
                        await model.create(title: title, startsAt: startsAt, venue: venue, kind: kind)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.plain).pill(Palette.lemon, Palette.onLemon, height: 36)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Color(hex: 0x1E1640))
    }

    private func field(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.round(15, .semibold))
            .foregroundStyle(.white)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
    }
}
