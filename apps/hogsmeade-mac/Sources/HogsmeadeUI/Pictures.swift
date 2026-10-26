import AppKit
import HogsmeadeCore
import SwiftUI

// The picture with an outing, as Hedwig shows it: loaded once per version
// through the model's cache, and the title's colours when there is none.

extension HSL {
    public var color: Color {
        let c = rgb
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}

extension OutingPicture {
    public var swiftUI: Image { Image(decorative: image, scale: 1) }
}

/// Loads the outing's picture once per version and hands it to `content`.
public struct OutingPictureReader<Content: View>: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    let content: (OutingPicture?) -> Content
    @State private var loaded: OutingPicture?

    public init(outing: Outing, @ViewBuilder content: @escaping (OutingPicture?) -> Content) {
        self.outing = outing
        self.content = content
    }

    public var body: some View {
        content(outing.image == nil ? nil : model.cachedPicture(for: outing) ?? loaded)
            .task(id: "\(outing.id)|\(outing.image?.updatedAt.timeIntervalSince1970 ?? 0)") {
                loaded = await model.picture(for: outing)
            }
    }
}

/// An outing without a picture: a rich gradient in the title's colours and
/// the kind's symbol, wherever a picture would be.
public struct OutingArt: View {
    let outing: Outing
    var symbolSize: CGFloat
    var stripes: Bool

    public init(outing: Outing, symbolSize: CGFloat = 40, stripes: Bool = false) {
        self.outing = outing
        self.symbolSize = symbolSize
        self.stripes = stripes
    }

    public var body: some View {
        let colours = TitleColours(title: outing.title)
        let top = HSL(hue: colours.glow.hue, saturation: 0.62, lightness: 0.5)
        let bottom = HSL(hue: colours.end.hue, saturation: 0.58, lightness: 0.26)
        ZStack {
            LinearGradient(colors: [top.color, colours.start.color, bottom.color], startPoint: .topLeading, endPoint: .bottomTrailing)
            if stripes {
                Stripes(angle: Double(TitleColours.seed(outing.title) % 180))
            }
            RadialGradient(colors: [.white.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: symbolSize * 4)
            Image(systemName: outing.kindSymbol)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.25), radius: symbolSize * 0.12, y: symbolSize * 0.05)
        }
    }
}

/// Faint diagonal stripes, like the posters in the playful design.
struct Stripes: View {
    var angle: Double

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height) * 2
            HStack(spacing: 11) {
                ForEach(0..<Int(side / 18) + 1, id: \.self) { _ in
                    Rectangle().fill(.white.opacity(0.07)).frame(width: 7)
                }
            }
            .frame(width: side, height: side)
            .rotationEffect(.degrees(angle))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

extension TitleColours {
    /// The design's hash, so the stripes turn the same way every time.
    public static func seed(_ title: String) -> Int {
        Int(title.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value } % 1000)
    }
}

/// The outing's picture filling its frame, or its art when there is none.
/// A small or square picture sits whole on a blurred copy of itself.
public struct OutingPoster: View {
    let outing: Outing
    var symbolSize: CGFloat
    var stripes: Bool
    var past: Bool

    public init(outing: Outing, symbolSize: CGFloat = 40, stripes: Bool = false, past: Bool = false) {
        self.outing = outing
        self.symbolSize = symbolSize
        self.stripes = stripes
        self.past = past
    }

    public var body: some View {
        OutingPictureReader(outing: outing) { picture in
            Color.clear
                .overlay {
                    if let picture {
                        if picture.fit == .fill {
                            picture.swiftUI.resizable().scaledToFill()
                        } else {
                            ZStack {
                                picture.swiftUI.resizable().scaledToFill().blur(radius: 12, opaque: true).brightness(-0.1)
                                picture.swiftUI.resizable().scaledToFit()
                            }
                        }
                    } else {
                        OutingArt(outing: outing, symbolSize: symbolSize, stripes: stripes)
                    }
                }
                .clipped()
                .grayscale(past ? 0.6 : 0)
                .brightness(past ? -0.15 : 0)
        }
    }
}

/// The weekday, day and month of an outing, as a small block.
public struct DateTile: View {
    let date: Date
    var large: Bool

    public init(date: Date, large: Bool = false) {
        self.date = date
        self.large = large
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(OutingFormat.month(date).uppercased())
                .font(.system(size: large ? 11 : 10, weight: .bold))
                .foregroundStyle(Color(hex: 0xA24E1D))
            Text(OutingFormat.day(date))
                .font(.system(size: large ? 32 : 20, weight: .heavy, design: .rounded))
                .monospacedDigit()
            if large {
                Text(OutingFormat.weekday(date))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x6B655D))
            }
        }
        .foregroundStyle(Color(hex: 0x1F1C18))
        .frame(width: large ? 70 : 46, height: large ? 78 : 46)
        .background(.white, in: RoundedRectangle(cornerRadius: large ? 14 : 10))
        .shadow(color: .black.opacity(0.18), radius: large ? 6 : 3, y: 2)
        .accessibilityLabel(OutingFormat.date(date))
    }
}

extension OutingFormat {
    /// "vrijdag"
    public static func weekday(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    /// "Deuren 20:00 · tot 04:00", what is known.
    public static func times(_ outing: Outing, calendar: Calendar = .current) -> String? {
        var parts: [String] = []
        if let doors = outing.doorsAt { parts.append("Deuren \(time(doors, calendar: calendar))") }
        if let end = outing.endsAt, calendar.isDate(end, inSameDayAs: outing.startsAt) || outing.doorsAt != nil {
            parts.append("tot \(time(end, calendar: calendar))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
