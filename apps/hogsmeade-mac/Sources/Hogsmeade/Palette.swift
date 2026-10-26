import SwiftUI

/// Hogsmeade's own colours, from docs/design/hogsmeade-style.html: a night
/// for the wall, cream for the scrapbook and candy for stickers. Fixed, not
/// dynamic: the playfulness is the point.
enum Palette {
    static let night = Color(hex: 0x140F2A)
    static let nightDeep = Color(hex: 0x0E0A1F)
    static let ink = Color(hex: 0x1F1C18)
    static let cream = Color(hex: 0xFBF5E9)
    static let violet = Color(hex: 0x7A3FC9)
    static let lemon = Color(hex: 0xF6D45B)
    static let mint = Color(hex: 0x8EDCC0)
    static let sky = Color(hex: 0x8CC6F0)
    static let lilac = Color(hex: 0xC9A8F2)
    static let peach = Color(hex: 0xF7B389)
    static let candy = Color(hex: 0xF59BC1)
    static let hot = Color(hex: 0xE0589A)
    static let mutedOnNight = Color(hex: 0xCFC8E2)
    static let dimOnNight = Color(hex: 0x9B93B6)
    static let mutedOnCream = Color(hex: 0x5A5272)
    static let faintOnCream = Color(hex: 0x8A7FA8)

    /// On a lemon sticker.
    static let onLemon = Color(hex: 0x3B2E00)
    static let onMint = Color(hex: 0x0F3B2E)

    static let confetti: [Color] = [lemon, mint, sky, lilac, peach, candy, .white]
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

extension Font {
    /// SF Pro Rounded, the friendly face of the system font.
    static func round(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Poster lettering: the system font squeezed, in capitals (see `.poster()`).
    static func poster(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy).width(.condensed)
    }
}

extension View {
    /// Big uppercase lettering as on a poster.
    func poster(_ size: CGFloat) -> some View {
        font(.poster(size)).textCase(.uppercase)
    }
}

// MARK: Stickers and stamps

/// A round sticker with a word or two, slightly turned, like on a fridge.
struct Sticker<Content: View>: View {
    var colour: Color = Palette.lemon
    var text: Color = Palette.onLemon
    var size: CGFloat = 58
    var angle: Double = -8
    @ViewBuilder let content: Content

    var body: some View {
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
struct Stamp: View {
    let text: String
    var colour: Color = Palette.mint
    var angle: Double = 10
    var size: CGFloat = 13

    var body: some View {
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
    var height: CGFloat = 32

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
    func pill(_ fill: Color, _ text: Color, height: CGFloat = 32) -> some View {
        modifier(Pill(fill: fill, text: text, height: height))
    }
}

/// Washi tape across a corner.
struct Tape: View {
    var colour: Color
    var angle: Double

    var body: some View {
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

// MARK: Confetti

/// A burst of confetti over the whole view, once per trigger.
struct ConfettiBurst: View {
    let trigger: UUID?
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

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { context in
            Canvas { canvas, size in
                guard let start else { return }
                let t = context.date.timeIntervalSince(start)
                for piece in pieces {
                    let life = t - piece.delay
                    guard life > 0, life < 4.2 else { continue }
                    let y = -20 + life * piece.speed * size.height / 4
                    let x = piece.x * size.width + sin(life * 2.4 + piece.spin) * piece.drift
                    let rect = CGRect(x: -piece.width / 2, y: -piece.height / 2, width: piece.width, height: piece.height)
                    var ctx = canvas
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .degrees(life * 320 + piece.spin * 90))
                    ctx.opacity = life > 3.4 ? max(0, 1 - (life - 3.4) / 0.8) : 1
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(piece.colour))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) {
            guard trigger != nil else { return }
            pieces = (0..<90).map { i in
                Piece(
                    x: .random(in: 0...1), delay: .random(in: 0...0.7), speed: .random(in: 0.8...1.6),
                    spin: .random(in: 0...6), width: .random(in: 7...14), height: .random(in: 10...20),
                    colour: Palette.confetti[i % Palette.confetti.count], drift: .random(in: 10...40))
            }
            start = .now
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if trigger == self.trigger { start = nil }
            }
        }
    }
}

/// The soft blurred lights behind the wall.
struct Orbs: View {
    var body: some View {
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
