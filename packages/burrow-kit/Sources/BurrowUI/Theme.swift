import AppKit
import SwiftUI

/// The Burrow palette from docs/design/burrow-design-system.html as the Mac
/// apps use it: status colours, a colour per app and per person. The apps
/// draw everything else in system colours. Every colour has a light and a
/// dark value.
public enum BurrowColor {
    public static let success = dynamic(0x2A7549, 0x5FCB85)
    public static let warning = dynamic(0x9A5B00, 0xF0B24A)
    public static let danger = dynamic(0xC8372D, 0xF07A6E)
    public static let info = dynamic(0x2F6FB5, 0x7FB2F0)

    public static let hedwig = dynamic(0x4E6E9E, 0x9DB7DC)
    public static let pensieve = dynamic(0x237A6F, 0x6FCDBF)
    public static let lumos = dynamic(0x735B84, 0xC9AEDC)
    public static let hogsmeade = dynamic(0x7A3FC9, 0xC9A6FF)

    static let people = [
        dynamic(0x3B4A6B, 0x9FB0D6), // ink
        dynamic(0x8A4FA3, 0xCFA3E6), // heather
        dynamic(0x237A6F, 0x6FCDBF),
        dynamic(0x85660F, 0xE3BE4F),
    ]

    /// A person's colour for avatars and ownership marks, the same on every
    /// Mac and every launch.
    public static func person(_ name: String) -> Color {
        let stable = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return people[stable % people.count]
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// A round initial in the person's colour.
public struct PersonBadge: View {
    let name: String
    var size: CGFloat = 22

    public init(_ name: String, size: CGFloat = 22) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(BurrowColor.person(name)))
            .accessibilityLabel(name)
    }
}

/// A task's status as a small coloured capsule, in Dutch.
public struct StatusPill: View {
    let status: String

    public init(_ status: String) { self.status = status }

    public var body: some View {
        Text(Self.label(status))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    var color: Color {
        switch status {
        case "done": BurrowColor.success
        case "failed": BurrowColor.danger
        case "review": BurrowColor.warning
        case "running", "compressing", "transcribing", "writing-notes": BurrowColor.info
        default: .secondary
        }
    }

    public static func label(_ status: String) -> String {
        switch status {
        case "queued": "In de wachtrij"
        case "running": "Bezig"
        case "review": "Wacht op jou"
        case "done": "Klaar"
        case "failed": "Mislukt"
        case "rejected": "Afgewezen"
        case "compressing": "Comprimeren"
        case "transcribing": "Transcriberen"
        case "writing-notes": "Notulen schrijven"
        default: status
        }
    }
}
