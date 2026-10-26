import SwiftUI

/// Hogsmeade Feest's own colours, from docs/design/hogsmeade-style.html: a
/// night for the wall, cream for the scrapbook and candy for stickers. Fixed,
/// not dynamic: the playfulness is the point. The native face uses the
/// Burrow tokens and only borrows the confetti colours.
public enum Palette {
    public static let night = Color(hex: 0x140F2A)
    public static let nightDeep = Color(hex: 0x0E0A1F)
    public static let ink = Color(hex: 0x1F1C18)
    public static let cream = Color(hex: 0xFBF5E9)
    public static let violet = Color(hex: 0x7A3FC9)
    public static let lemon = Color(hex: 0xF6D45B)
    public static let mint = Color(hex: 0x8EDCC0)
    public static let sky = Color(hex: 0x8CC6F0)
    public static let lilac = Color(hex: 0xC9A8F2)
    public static let peach = Color(hex: 0xF7B389)
    public static let candy = Color(hex: 0xF59BC1)
    public static let hot = Color(hex: 0xE0589A)
    public static let mutedOnNight = Color(hex: 0xCFC8E2)
    public static let dimOnNight = Color(hex: 0x9B93B6)
    public static let mutedOnCream = Color(hex: 0x5A5272)
    public static let faintOnCream = Color(hex: 0x8A7FA8)

    /// On a lemon sticker.
    public static let onLemon = Color(hex: 0x3B2E00)
    public static let onMint = Color(hex: 0x0F3B2E)
    public static let onSky = Color(hex: 0x143557)
    public static let onCandy = Color(hex: 0x5A1C3A)
    public static let onPeach = Color(hex: 0x5A2A00)

    public static let confetti: [Color] = [lemon, mint, sky, lilac, peach, candy, .white]

    /// A person's own colour, the same everywhere, from their name.
    public static func person(_ name: String) -> (fill: Color, text: Color) {
        let pairs: [(Color, Color)] = [(sky, onSky), (candy, onCandy), (mint, onMint), (peach, onPeach), (lilac, Color(hex: 0x3B2360)), (lemon, onLemon)]
        let index = name.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7FFFFFFF } % pairs.count
        return pairs[index]
    }
}

extension Color {
    public init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

extension Font {
    /// SF Pro Rounded, the friendly face of the system font.
    public static func round(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Poster lettering: the system font squeezed, in capitals (see `.poster()`).
    public static func poster(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy).width(.condensed)
    }
}

extension View {
    /// Big uppercase lettering as on a poster.
    public func poster(_ size: CGFloat) -> some View {
        font(.poster(size)).textCase(.uppercase)
    }
}

// MARK: Stickers and stamps

/// A round sticker with a word or two, slightly turned, like on a fridge.
public struct Sticker<Content: View>: View {
    var colour: Color
    var text: Color
    var size: CGFloat
    var angle: Double
    let content: Content

    public init(colour: Color = Palette.lemon, text: Color = Palette.onLemon, size: CGFloat = 58, angle: Double = -8, @ViewBuilder content: () -> Content) {
        self.colour = colour
        self.text = text
        self.size = size
        self.angle = angle
        self.content = content()
    }

    public var body: some View {
        content
            .foregroundStyle(text)
            .multilineTextAlignment(.center)
            .frame(width: size, height: size)
            .background(Circle().fill(colour))
            .rotationEffect(.degrees(angle))
            .shadow(color: .black.opacity(0.25), radius: 5, y: 3)
    }
}

/// A rubber stamp: outlined capitals, a little askew.
public struct Stamp: View {
    let text: String
    var colour: Color
    var angle: Double
    var size: CGFloat

    public init(_ text: String, colour: Color = Palette.mint, angle: Double = 10, size: CGFloat = 13) {
        self.text = text
        self.colour = colour
        self.angle = angle
        self.size = size
    }

    public var body: some View {
        Text(text)
            .poster(size)
            .kerning(0.6)
            .foregroundStyle(colour)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(colour, lineWidth: 2.5))
            .rotationEffect(.degrees(angle))
            .blendMode(.screen)
    }
}

/// A flat pill, for facts and chips.
struct Pill: ViewModifier {
    var fill: Color
    var text: Color
    var height: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.round(13, .bold))
            .foregroundStyle(text)
            .padding(.horizontal, 13)
            .frame(height: height)
            .background(Capsule().fill(fill))
    }
}

extension View {
    public func pill(_ fill: Color, _ text: Color, height: CGFloat = 32) -> some View {
        modifier(Pill(fill: fill, text: text, height: height))
    }
}

/// Washi tape across a corner.
public struct Tape: View {
    var colour: Color
    var angle: Double

    public init(colour: Color, angle: Double) {
        self.colour = colour
        self.angle = angle
    }

    public var body: some View {
        Rectangle()
            .fill(colour.opacity(0.75))
            .frame(width: 110, height: 28)
            .overlay(
                HStack(spacing: 4) {
                    ForEach(0..<18, id: \.self) { _ in Rectangle().fill(.white.opacity(0.35)).frame(width: 2) }
                }
            )
            .rotationEffect(.degrees(angle))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
    }
}

/// A person's initial in their colour.
public struct Avatar: View {
    let name: String
    var size: CGFloat

    public init(_ name: String, size: CGFloat = 28) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        let colours = Palette.person(name)
        Text(name.prefix(1).uppercased())
            .font(.round(size * 0.44, .heavy))
            .foregroundStyle(colours.text)
            .frame(width: size, height: size)
            .background(Circle().fill(colours.fill))
            .accessibilityLabel(name)
    }
}

// MARK: Confetti

/// Confetti over the whole view: a burst once per trigger, or falling for as
/// long as `continuous` is on (the night itself).
public struct ConfettiBurst: View {
    let trigger: UUID?
    var continuous: Bool
    @State private var start: Date?
    @State private var pieces: [Piece] = []

    struct Piece {
        var x: Double
        var delay: Double
        var speed: Double
        var spin: Double
        var width: Double
        var height: Double
        var colour: Color
        var drift: Double
    }

    public init(trigger: UUID?, continuous: Bool = false) {
        self.trigger = trigger
        self.continuous = continuous
    }

    public var body: some View {
        TimelineView(.animation(paused: start == nil)) { context in
            Canvas { canvas, size in
                guard let start else { return }
                let t = context.date.timeIntervalSince(start)
                for piece in pieces {
                    var life = t - piece.delay
                    if continuous {
                        guard life > 0 else { continue }
                        life = life.truncatingRemainder(dividingBy: 8)
                    } else {
                        guard life > 0, life < 4.2 else { continue }
                    }
                    let y = -20 + life * piece.speed * size.height / 4
                    let x = piece.x * size.width + sin(life * 2.4 + piece.spin) * piece.drift
                    let rect = CGRect(x: -piece.width / 2, y: -piece.height / 2, width: piece.width, height: piece.height)
                    var ctx = canvas
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .degrees(life * 320 + piece.spin * 90))
                    ctx.opacity = !continuous && life > 3.4 ? max(0, 1 - (life - 3.4) / 0.8) : 1
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(piece.colour))
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { if continuous { fire(count: 60, spread: 8) } }
        .onChange(of: trigger) {
            guard trigger != nil else { return }
            fire(count: 90, spread: 0.7)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if !continuous, trigger == self.trigger { start = nil }
            }
        }
    }

    private func fire(count: Int, spread: Double) {
        pieces = (0..<count).map { i in
            Piece(
                x: .random(in: 0...1), delay: .random(in: 0...spread), speed: .random(in: 0.5...1.2),
                spin: .random(in: 0...6), width: .random(in: 7...14), height: .random(in: 10...20),
                colour: Palette.confetti[i % Palette.confetti.count], drift: .random(in: 10...40))
        }
        start = .now
    }
}

/// The soft blurred lights behind the wall.
public struct Orbs: View {
    public init() {}

    public var body: some View {
        ZStack {
            Circle().fill(Color(hex: 0x5B2AA8)).frame(width: 620).offset(x: -420, y: -360)
            Circle().fill(Color(hex: 0xE0589A).opacity(0.5)).frame(width: 520).offset(x: 480, y: -120)
            Circle().fill(Color(hex: 0x237A6F).opacity(0.5)).frame(width: 360).offset(x: -40, y: 420)
        }
        .blur(radius: 70)
        .opacity(0.75)
        .allowsHitTesting(false)
    }
}

