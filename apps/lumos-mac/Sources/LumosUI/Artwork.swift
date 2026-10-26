import LumosCore
import SwiftUI

/// The server's picture when there is one; otherwise a calm tile in the
/// title's own colours, so test titles never borrow real artwork.
public struct Artwork: View {
    /// Decode sizes: a poster card is 124 pt wide on a 2x screen, a still 250 pt.
    public static let posterPixels = 360
    public static let widePixels = 640

    let title: TitleSummary
    let style: TitleRow.Style
    let maxPixels: Int
    let placeholderTitle: Bool

    /// `placeholderTitle` is off when the view writes the title itself.
    public init(title: TitleSummary, style: TitleRow.Style, maxPixels: Int? = nil, placeholderTitle: Bool = true) {
        self.title = title
        self.style = style
        self.maxPixels = maxPixels ?? (style == .wide ? Self.widePixels : Self.posterPixels)
        self.placeholderTitle = placeholderTitle
    }

    public var body: some View {
        let url = (style == .wide ? title.backdrop ?? title.poster : title.poster).flatMap(URL.init(string:))
        CachedImage(url: url, maxPixels: maxPixels) {
            Placeholder(title: title, style: style, showsTitle: placeholderTitle)
        }
    }
}

public struct Placeholder: View {
    let title: TitleSummary
    let style: TitleRow.Style
    var showsTitle = true

    public init(title: TitleSummary, style: TitleRow.Style, showsTitle: Bool = true) {
        self.title = title
        self.style = style
        self.showsTitle = showsTitle
    }

    public var body: some View {
        let colours = TileColours(title.title)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [colours.start, colours.end], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: title.mediaType == .tv ? "tv" : "film")
                .font(.system(size: style == .wide ? 54 : 40, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.13))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: style == .wide ? .trailing : .center)
                .padding(style == .wide ? 18 : 0)
            if showsTitle {
                Text(title.title)
                    .font(.system(size: style == .wide ? 17 : 14, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 4)
                    .lineLimit(3)
                    .padding(10)
            }
        }
    }
}

/// Two dark shades from the title, always the same for the same title.
public struct TileColours {
    public let start: Color
    public let end: Color

    public init(_ title: String) {
        let hash = title.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
        let hue = Double(hash % 360) / 360
        start = Color(hue: hue, saturation: 0.42, brightness: 0.48)
        end = Color(hue: (hue + 0.11).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.26)
    }
}

