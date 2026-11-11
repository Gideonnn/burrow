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
                        Text(heading(tonight: tonight != nil)).font(.title2.bold()).fontDesign(.rounded)
                        Text(rest.count == 1 ? "1 uitje" : "\(rest.count) uitjes").foregroundStyle(.secondary)
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

/// Tonight: the gradient, the facts and the two buttons that matter on the day.
struct TonightBanner: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    @State private var viewing: ViewingTicket?

    var body: some View {
        HStack(spacing: 20) {
            Button { model.open(outing.id) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(outing.dayWord()) is het zover")
                        .font(.subheadline.weight(.semibold)).textCase(.uppercase).opacity(0.9)
                    Text(outing.title)
                        .font(.largeTitle.weight(.heavy)).fontDesign(.rounded).lineLimit(2)
                    HStack(spacing: 16) {
                        if let times = OutingFormat.times(outing) ?? (outing.allDay ? nil : OutingFormat.time(outing.startsAt)) {
                            Label(times, systemImage: "clock")
                        }
                        if let first = OutingFormat.whereLines(outing).first {
                            Label([first, outing.city].compactMap { $0 }.joined(separator: ", "), systemImage: "mappin.and.ellipse")
                        }
                        if let who = OutingsModel.sentence(outing.attendees.map(\.name)) { Text(who) }
                    }
                    .font(.callout).opacity(0.95).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white)
            .accessibilityLabel("\(outing.title), \(outing.dayWord().lowercased()); open de pagina")
            VStack(spacing: 8) {
                TicketEntriesReader(outing: outing) { entries in
                    Button {
                        if entries.isEmpty { model.open(outing.id) } else { viewing = ViewingTicket(index: 0) }
                    } label: {
                        Label(entries.isEmpty ? "Kaartjes" : (entries.count == 1 ? "Kaartje" : "\(entries.count) kaartjes"), systemImage: "ticket")
                            .frame(maxWidth: .infinity)
                    }
                    .modifier(BannerButtonStyle(prominent: true))
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
                            .modifier(BannerButtonStyle(prominent: false))
                        }
                    }
                }
            }
            .controlSize(.large)
            .frame(width: 170)
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        .background {
            LinearGradient(colors: [Color(hex: 0x5B2AA8), Color(hex: 0x8A3FD1), Color(hex: 0xE0589A)], startPoint: .leading, endPoint: .trailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
    }
}

/// Glass on the gradient from macOS 26, the bordered styles before.
private struct BannerButtonStyle: ViewModifier {
    var prominent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}

/// One poster: the picture with the date and the nights left, the title,
/// kind and place, the status chip and who goes.
struct PosterCard: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    var past = false

    var body: some View {
        Button { model.open(outing.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                art
                VStack(alignment: .leading, spacing: 2) {
                    Text(outing.title).font(.headline).fontDesign(.rounded).lineLimit(1)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    HStack(alignment: .center) {
                        StatusChip(status: outing.status(now: model.now()), past: past)
                        Spacer(minLength: 4)
                        if !past {
                            HStack(spacing: -5) {
                                ForEach(outing.attendees, id: \.id) { person in
                                    Avatar(person.name, size: 20).overlay(Circle().strokeBorder(.background, lineWidth: 2))
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .foregroundStyle(.primary)
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
            }
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.borderless)
        .contextMenu { OutingMenu(outing: outing) }
        .accessibilityLabel("\(outing.title), \(OutingFormat.when(outing))")
    }

    private var subtitle: String {
        past ? "Geweest · \(OutingFormat.date(outing.startsAt))" : outing.kindAndVenue.nilIfEmpty ?? OutingFormat.when(outing)
    }

    private var art: some View {
        OutingPoster(outing: outing, symbolSize: 36, past: past)
            .frame(height: 128)
            .overlay(alignment: .topLeading) { DateTile(date: outing.startsAt).padding(10) }
            .overlay(alignment: .bottomTrailing) {
                if !past {
                    Text(model.nightsLabel(outing))
                        .font(.caption.weight(.semibold)).fontDesign(.rounded)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
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
            if status.tone == .done { Image(systemName: "checkmark").font(.caption2.bold()) }
            Text(past ? "Was het leuk?" : status.text).lineLimit(1)
        }
        .font(.caption.weight(status.tone == .later || past ? .regular : .medium))
        .foregroundStyle(colour)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(colour.opacity(0.12), in: Capsule())
    }

    private var colour: AnyShapeStyle {
        if past { return AnyShapeStyle(.secondary) }
        switch status.tone {
        case .done: return AnyShapeStyle(BurrowColor.success)
        case .todo: return AnyShapeStyle(BurrowColor.warning)
        case .today: return AnyShapeStyle(.tint)
        case .later, .past: return AnyShapeStyle(.secondary)
        }
    }
}
