import SwiftUI

/// A person's initial in their own colour, the same everywhere, from their name.
public struct Avatar: View {
    let name: String
    var size: CGFloat

    public init(_ name: String, size: CGFloat = 28) {
        self.name = name
        self.size = size
    }

    private static let colours: [Color] = [.blue, .pink, .mint, .orange, .purple, .yellow]

    public var body: some View {
        let index = name.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7FFFFFFF } % Self.colours.count
        Text(name.prefix(1).uppercased())
            // Sized to the circle, not to the reader's text size.
            .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Self.colours[index].gradient))
            .accessibilityLabel(name)
    }
}

extension Color {
    public init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
