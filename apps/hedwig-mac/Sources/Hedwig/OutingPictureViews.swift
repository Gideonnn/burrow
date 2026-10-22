import AppKit
import HedwigCore
import SwiftUI
import UniformTypeIdentifiers

// The picture with an outing (docs/design/hedwig-event-images.html): the
// thumbnail in the list and on the mail card, the hero on the page, the
// Afbeelding part of Details and the sheet to pick another.

extension HSL {
    var color: Color {
        let c = rgb
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}

extension OutingPicture {
    var swiftUI: Image { Image(decorative: image, scale: 1) }
}

/// Loads the outing's picture once per version and hands it to `content`.
struct OutingPictureReader<Content: View>: View {
    @Environment(AppModel.self) private var model
    let outing: Outing
    @ViewBuilder let content: (OutingPicture?) -> Content
    @State private var loaded: OutingPicture?

    var body: some View {
        content(outing.image == nil ? nil : model.cachedPicture(for: outing) ?? loaded)
            .task(id: outing.image?.updatedAt) { loaded = await model.picture(for: outing) }
    }
}

/// The calm band for an outing without a picture: two dark colours from the
/// title, a soft glow and a few rings, the same every time.
struct TitleColourArt: View {
    let title: String
    var rings = true

    var body: some View {
        let colours = TitleColours(title: title)
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(colors: [colours.start.color, colours.end.color]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            // The design draws on 1200 × 630 and covers the frame with it.
            let scale = max(size.width / 1200, size.height / 630)
            let origin = CGPoint(x: (size.width - 1200 * scale) / 2, y: (size.height - 630 * scale) * 0.4)
            let centre = CGPoint(x: origin.x + 930 * scale, y: origin.y + 130 * scale)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 70 * scale))
                let r = 230 * scale
                layer.fill(
                    Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)),
                    with: .color(colours.glow.color.opacity(0.5)))
            }
            guard rings else { return }
            for radius in stride(from: 140.0, through: 860, by: 90) {
                let r = radius * scale
                context.stroke(
                    Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)),
                    with: .color(.white.opacity(0.07)), lineWidth: max(1, 2 * scale))
            }
        }
    }
}

/// A picture covering its frame; small or square ones sit whole on a
/// blurred copy of themselves, as in the hero.
struct PictureTile: View {
    let picture: OutingPicture
    var blur: CGFloat = 10
    /// The hero draws the sharp copy itself, beside the title.
    var sharp = true

    var body: some View {
        Color.clear
            .overlay {
                if picture.fit == .fill {
                    picture.swiftUI.resizable().scaledToFill()
                } else {
                    ZStack {
                        picture.swiftUI.resizable().scaledToFill().blur(radius: blur, opaque: true).brightness(-0.1)
                        if sharp { picture.swiftUI.resizable().scaledToFit() }
                    }
                }
            }
            .clipped()
    }
}

/// The list row's and mail card's thumbnail. Without a picture the list
/// shows a calm tile; the mail card shows nothing.
struct OutingThumbnail: View {
    @Environment(\.colorScheme) private var scheme
    let outing: Outing
    var width: CGFloat = 44
    var height: CGFloat = 44
    var past = false

    var body: some View {
        OutingPictureReader(outing: outing) { picture in
            Group {
                if let picture {
                    Color.clear.overlay { picture.swiftUI.resizable().scaledToFill() }.clipped()
                } else if outing.image != nil {
                    Color.secondary.opacity(0.15)
                } else {
                    TitleColourArt(title: outing.title, rings: false)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.black.opacity(0.08)))
            .grayscale(past ? 1 : 0)
            .brightness(scheme == .dark ? -0.06 : 0)
        }
        .accessibilityHidden(true)
    }
}

/// An outing without a picture: a rich gradient in the title's colours and
/// the kind's symbol, wherever a picture would be.
struct OutingArtFallback: View {
    let outing: Outing
    var symbolSize: CGFloat = 40

    var body: some View {
        let colours = TitleColours(title: outing.title)
        let top = HSL(hue: colours.glow.hue, saturation: 0.62, lightness: 0.5)
        let bottom = HSL(hue: colours.end.hue, saturation: 0.58, lightness: 0.26)
        ZStack {
            LinearGradient(colors: [top.color, colours.start.color, bottom.color], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: symbolSize * 4)
            Image(systemName: outing.kindSymbol)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.25), radius: symbolSize * 0.12, y: symbolSize * 0.05)
        }
    }
}

// MARK: The top of the page

/// The top of the page: a large picture fills the right two thirds and fades
/// into the title on the left; a small or tall one stays whole in a frame on
/// the right, where it would turn blurry or lose its top and bottom.
/// Pasting or dropping a picture or a link here sets it.
struct OutingHero: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let outing: Outing
    /// The picture's height at most; the page keeps the header to about a
    /// third of the window.
    var maxArt: CGFloat = 160
    let pick: () -> Void
    @State private var hovering = false
    @State private var dropping = false
    @State private var column: CGFloat = 584
    @State private var pane: CGFloat = 800
    /// Placing the picture: the frame being edited, and where a drag or a
    /// pinch started.
    @State private var editing: PictureFrame?
    @State private var gestureStart: PictureFrame?

    /// Large and not tall: worth filling two thirds of the header with.
    static func fills(_ picture: OutingPicture) -> Bool {
        picture.width >= 700 && Double(picture.width) / Double(max(picture.height, 1)) >= 0.9
    }

    /// The picture, or the kind's colours without one, over the right two
    /// thirds, fading to the left into the title and to the bottom into the page.
    private var artBox: CGSize { CGSize(width: pane * 0.74, height: height) }

    private func fadedArt(_ picture: OutingPicture?) -> some View {
        Group {
            if let picture {
                let image = CGSize(width: picture.width, height: picture.height)
                let placed = (editing ?? outing.image?.frame ?? .centred).layout(image: image, box: artBox)
                picture.swiftUI.resizable()
                    .frame(width: placed.size.width, height: placed.size.height)
                    .offset(x: placed.origin.x, y: placed.origin.y)
                    .frame(width: artBox.width, height: artBox.height, alignment: .topLeading)
            } else {
                OutingArtFallback(outing: outing, symbolSize: maxArt * 0.4)
            }
        }
        .frame(width: artBox.width, height: artBox.height)
        .clipped()
        // While placing, the whole box shows, so you see what you frame.
        .mask { editing == nil ? AnyView(horizontalFade) : AnyView(Color.black) }
        .mask { editing == nil ? AnyView(verticalFade) : AnyView(Color.black) }
        .overlay {
            if editing != nil {
                RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [5]))
            }
        }
        .contentShape(Rectangle())
        .gesture(placing(picture))
        .onHover { inside in
            guard editing != nil else { return }
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .allowsHitTesting(editing != nil)
    }

    private func placing(_ picture: OutingPicture?) -> some Gesture {
        let image = CGSize(width: picture?.width ?? 1, height: picture?.height ?? 1)
        let drag = DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let current = editing else { return }
                let start = gestureStart ?? current
                gestureStart = start
                editing = start.dragged(by: value.translation, image: image, box: artBox)
            }
            .onEnded { _ in gestureStart = nil }
        let pinch = MagnifyGesture()
            .onChanged { value in
                guard let current = editing else { return }
                let start = gestureStart ?? current
                gestureStart = start
                editing = start.zoomed(to: start.zoom * value.magnification, image: image, box: artBox)
            }
            .onEnded { _ in gestureStart = nil }
        return drag.simultaneously(with: pinch)
    }

    private var horizontalFade: some View {
            // An eased ramp over most of the width, so there is no visible edge.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.06), location: 0.12),
                    .init(color: .black.opacity(0.22), location: 0.26),
                    .init(color: .black.opacity(0.5), location: 0.42),
                    .init(color: .black.opacity(0.8), location: 0.58),
                    .init(color: .black.opacity(0.95), location: 0.72),
                    .init(color: .black, location: 0.82),
                ],
                startPoint: .leading, endPoint: .trailing)
    }

    private var verticalFade: some View {
            LinearGradient(
                // Bright at the top, dim behind the title, gone into the page.
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.38),
                    .init(color: .black.opacity(0.7), location: 0.58),
                    .init(color: .black.opacity(0.35), location: 0.78),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
    }

    private var canOrganize: Bool { model.me?.can(.organize) == true }

    private var height: CGFloat { maxArt + 60 }

    var body: some View {
        OutingPictureReader(outing: outing) { picture in
            let filled = picture.map(Self.fills) ?? (outing.image == nil)
            ZStack(alignment: .leading) {
                HeroBackdrop(outing: outing, picture: picture)
                if filled { fadedArt(picture) }
                HStack(alignment: .center, spacing: 22) {
                    titleBlock
                        .frame(maxWidth: filled ? max(260, pane * 0.48) : nil, alignment: .leading)
                    Spacer(minLength: 0)
                    if !filled { artwork(picture) }
                }
                .padding(.horizontal, 28)
                .padding(.top, 10)
                // Over a filled picture the title stands at the bottom, where
                // the picture has faded, like a film poster.
                .padding(.bottom, filled ? 22 : 0)
                .frame(
                    maxWidth: filled ? .infinity : 640, maxHeight: .infinity,
                    alignment: filled ? .bottomLeading : .leading)
                .opacity(editing == nil ? 1 : 0)
                .allowsHitTesting(editing == nil)
            }
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pane = $0; column = max(200, min(640, $0) - 56) }
            .overlay(alignment: .top) { controls(placeable: filled && picture != nil) }
            .overlay(alignment: .leading) {
                if let picture, editing != nil { placingBar(picture) }
            }
            .overlay { dropTarget }
        }
        .onChange(of: outing.id) { editing = nil }
        .clipped()
        .onHover { hovering = $0 }
        .onDrop(of: PastedContents.dropTypes, isTargeted: $dropping) { providers in
            guard canOrganize else { return false }
            Task { await model.setPicture(await PastedContents.load(providers), for: outing.id) }
            return true
        }
    }

    /// The picture whole, right of the title: at most `maxArt` high and 45 %
    /// of the width; small ones stay sharp at their own size.
    @ViewBuilder
    private func artwork(_ picture: OutingPicture?) -> some View {
        let maxWidth = column * 0.45
        if let picture {
            let scale = min(1, maxWidth / CGFloat(picture.width), maxArt / CGFloat(picture.height))
            picture.swiftUI
                .resizable()
                .frame(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
                .brightness(scheme == .dark ? -0.05 : 0)
        } else {
            let width = min(maxArt * 1.5, maxWidth)
            Group {
                if outing.image != nil {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                } else {
                    OutingArtFallback(outing: outing, symbolSize: maxArt * 0.32)
                }
            }
            .frame(width: width, height: min(maxArt, width / 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .center, spacing: 14) {
            GlassDateTile(date: outing.startsAt)
            VStack(alignment: .leading, spacing: 6) {
                Text(outing.title)
                    .font(.system(size: outing.title.count > 30 ? 21 : 26, weight: .bold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let kind = outing.kind {
                    Text(kind)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(0.08), in: Capsule())
                }
            }
        }
        .layoutPriority(1)
    }

    @ViewBuilder
    private func controls(placeable: Bool) -> some View {
        if canOrganize, editing == nil {
            HStack(spacing: 8) {
                if hovering {
                    Text("Plak of sleep een afbeelding")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if hovering, placeable {
                    Button { editing = outing.image?.frame ?? .centred } label: {
                        Label("Aanpassen", systemImage: "crop")
                    }
                    .buttonStyle(HeroPillStyle())
                    .help("Schuif de afbeelding op zijn plek of zoom in")
                }
                if hovering || model.pictureBusy.contains(outing.id) {
                    Button(action: pick) {
                        Label(outing.image == nil ? "Kies een afbeelding" : "Andere afbeelding", systemImage: "photo")
                    }
                    .buttonStyle(HeroPillStyle())
                }
                if model.pictureBusy.contains(outing.id) {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .padding(12)
        }
    }

    /// Zoom, back to the middle, and keep or drop what was placed.
    private func placingBar(_ picture: OutingPicture) -> some View {
        let image = CGSize(width: picture.width, height: picture.height)
        let zoom = Binding<Double>(
            get: { editing?.zoom ?? 1 },
            set: { editing = editing?.zoomed(to: $0, image: image, box: artBox) })
        // In the title's place, left of the picture, so it hides none of it.
        return VStack(alignment: .leading, spacing: 10) {
            Text("Afbeelding aanpassen").font(.headline)
            Text("Sleep de afbeelding of knijp om te zoomen.").font(.caption).foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: zoom, in: PictureFrame.zooms).frame(width: 120)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button("Midden") { editing = .centred }
                Button("Annuleer") { editing = nil }.keyboardShortcut(.cancelAction)
                Button("Gereed") {
                    let frame = editing
                    editing = nil
                    Task { await model.setPictureFrame(frame == .centred ? nil : frame, for: outing.id) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(.leading, 28)
    }

    @ViewBuilder
    private var dropTarget: some View {
        if dropping {
            ZStack {
                Color.black.opacity(0.45)
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(10)
                Label("Laat los voor de afbeelding", systemImage: "photo").font(.headline).foregroundStyle(.white)
            }
            .allowsHitTesting(false)
        }
    }
}

/// The date tile on a picture: light glass in light mode, dark in dark mode.
private struct GlassDateTile: View {
    @Environment(\.colorScheme) private var scheme
    let date: Date

    var body: some View {
        let dark = scheme == .dark
        VStack(spacing: 0) {
            Text(OutingFormat.month(date).uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(dark ? Color(red: 0.94, green: 0.55, blue: 0.68) : Color(red: 0.73, green: 0.26, blue: 0.42))
            Text(OutingFormat.day(date))
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(dark ? Color(red: 0.95, green: 0.93, blue: 0.91) : Color(red: 0.12, green: 0.11, blue: 0.09))
        }
        .frame(width: 58, height: 58)
        .background(dark ? Color(red: 0.14, green: 0.13, blue: 0.125).opacity(0.9) : Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

private struct HeroPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(.black.opacity(configuration.isPressed ? 0.7 : 0.58), in: Capsule())
    }
}

// MARK: Details › Afbeelding

struct OutingPictureSection: View {
    @Environment(AppModel.self) private var model
    let outing: Outing
    let pick: () -> Void

    private var canOrganize: Bool { model.me?.can(.organize) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OutingPictureReader(outing: outing) { picture in
                HStack(spacing: 12) {
                    Group {
                        if let picture { PictureTile(picture: picture) } else { OutingArtFallback(outing: outing, symbolSize: 22) }
                    }
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.label(outing.image?.source)).fontWeight(.semibold)
                        Text(Self.detail(outing.image, picture)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.pictureBusy.contains(outing.id) { ProgressView().controlSize(.small) }
                    Button("Andere afbeelding", action: pick).controlSize(.small)
                    if outing.image != nil {
                        Button("Geen afbeelding") { Task { await model.removePicture(from: outing.id) } }
                            .controlSize(.small)
                    }
                }
            }
            PictureDropZone(outingId: outing.id)
        }
        .disabled(!canOrganize)
    }

    static func label(_ source: OutingImage.Source?) -> String {
        switch source {
        case .mail: "Uit de mail"
        case .website: "Van de website"
        case .upload: "Zelf toegevoegd"
        case nil: "Geen afbeelding"
        }
    }

    static func detail(_ image: OutingImage?, _ picture: OutingPicture?) -> String {
        guard image != nil else { return "De kop krijgt kleuren bij de titel" }
        guard let picture else { return "Bewaard op de server" }
        let size = "\(picture.width) × \(picture.height) · bewaard op de server"
        return picture.fit == .framed ? "\(size) · klein, dus scherp op eigen maat met een vage rand" : size
    }
}

/// Where a picture or a link goes: dropped, pasted with ⌘V or with Plak.
struct PictureDropZone: View {
    @Environment(AppModel.self) private var model
    let outingId: String
    var done: (() -> Void)?
    @State private var dropping = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line")
            Text("Plak (⌘V) of sleep hier een afbeelding of een link")
            Spacer(minLength: 8)
            Button("Plak") { paste() }.controlSize(.small)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(dropping ? Color.pink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(dropping ? Color.pink : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4])))
        .onDrop(of: PastedContents.dropTypes, isTargeted: $dropping) { providers in
            Task { await set(await PastedContents.load(providers)) }
            return true
        }
    }

    private func paste() {
        let contents = NSPasteboard.general.pastedContents()
        Task { await set(contents) }
    }

    private func set(_ contents: PastedContents) async {
        if await model.setPicture(contents, for: outingId) { done?() }
    }
}

// MARK: Andere afbeelding

/// The pictures Hedwig found, fetched through the server, plus Geen. A
/// pasted or dropped picture is used straight away.
struct PicturePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let outing: Outing
    @State private var options: [OutingImageOption]?
    @State private var chosen: Choice?
    @State private var problem: String?

    enum Choice: Hashable { case option(OutingImageOption), none }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Afbeelding voor \(outing.title)").font(.title3.weight(.semibold)).lineLimit(1)
            Text(intro).font(.callout).foregroundStyle(.secondary)
            if options == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 100)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3), spacing: 8) {
                    ForEach(options ?? []) { option in
                        OptionTile(outing: outing, option: option, chosen: chosen == .option(option)) { chosen = .option(option) }
                    }
                    NoneTile(title: outing.title, chosen: chosen == Choice.none) { chosen = Choice.none }
                }
            }
            PictureDropZone(outingId: outing.id) { dismiss() }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("Kies een bestand…", action: pickFile)
                Spacer()
                Button("Annuleer", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Gebruik") { use() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    .disabled(chosen == nil || model.pictureBusy.contains(outing.id))
            }
        }
        .padding(20)
        .frame(width: 540)
        .background(PasteCatcher { Task { await set(NSPasteboard.general.pastedContents()) } })
        .task { options = await model.pictureOptions(for: outing.id) }
        .onChange(of: model.error) {
            // An alert cannot show over this sheet; say it here instead.
            if let error = model.error {
                problem = error
                model.error = nil
            }
        }
    }

    private var intro: String {
        if options?.isEmpty == true {
            return "Hedwig vond niets in de mail of op de website. Plak of sleep je eigen afbeelding hierheen, of houd de kleuren."
        }
        return "Hedwig vond deze. Kies er een, of plak of sleep je eigen afbeelding hierheen."
    }

    private func use() {
        guard let chosen else { return }
        Task {
            let done =
                switch chosen {
                case .option(let option): await model.choosePicture(option, for: outing.id)
                case .none: outing.image == nil ? true : await model.removePicture(from: outing.id)
                }
            if done { dismiss() }
        }
    }

    private func set(_ contents: PastedContents) async {
        problem = nil
        if await model.setPicture(contents, for: outing.id) { dismiss() }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Kies een afbeelding voor \(outing.title)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await set(PastedContents(fileURLs: [url])) }
    }
}

private struct OptionTile: View {
    @Environment(AppModel.self) private var model
    let outing: Outing
    let option: OutingImageOption
    let chosen: Bool
    let choose: () -> Void
    @State private var picture: OutingPicture?
    @State private var loading = true

    var body: some View {
        CandidateTile(chosen: chosen, choose: choose) {
            if let picture {
                PictureTile(picture: picture)
            } else if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        } label: {
            Text(option.source == .mail ? "Uit de mail" : "Van de website").font(.callout.weight(.semibold))
            Text(picture.map { "\($0.width) × \($0.height)" } ?? " ").font(.caption).foregroundStyle(.secondary)
        }
        .task {
            picture = await model.pictureOption(option, of: outing.id)
            loading = false
        }
    }
}

private struct NoneTile: View {
    let title: String
    let chosen: Bool
    let choose: () -> Void

    var body: some View {
        CandidateTile(chosen: chosen, choose: choose) {
            TitleColourArt(title: title, rings: false)
        } label: {
            Text("Geen").font(.callout.weight(.semibold))
            Text("kleuren bij de titel").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CandidateTile<Art: View, Label: View>: View {
    let chosen: Bool
    let choose: () -> Void
    @ViewBuilder let art: () -> Art
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                Color.secondary.opacity(0.1)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { art() }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                VStack(alignment: .leading, spacing: 0) { label() }
            }
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(chosen ? Color.pink : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: The pasteboard

extension NSPasteboard {
    /// The original formats first; TIFF and HEIC are what Safari, Mail and
    /// Photos add, and are converted before the upload.
    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .init(UTType.jpeg.identifier), .init(UTType.gif.identifier), .init(UTType.webP.identifier),
        .tiff, .init(UTType.heic.identifier),
    ]

    func pastedContents() -> PastedContents {
        let files = readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let urls = (readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter { !$0.isFileURL }
        let image = Self.imageTypes.lazy.compactMap { self.data(forType: $0) }.first
        return PastedContents(
            fileURLs: files, images: image.map { [$0] } ?? [], urls: urls, strings: string(forType: .string).map { [$0] } ?? [])
    }
}

/// Catches ⌘V in its own window while no text field is being edited, so a
/// picture can be pasted onto the page without clicking anything first.
struct PasteCatcher: NSViewRepresentable {
    let paste: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) { view.paste = paste }

    final class CatcherView: NSView {
        var paste: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) == true }
                return handled ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.attachedSheet == nil,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  !(window.firstResponder is NSText), let paste
            else { return false }
            paste()
            return true
        }
    }
}

/// The header's backdrop: the picture's own strong colours as a soft
/// gradient fading into the page, light behind black text and deep behind
/// white. A blurred copy would smear the artwork's dark parts into grey.
private struct HeroBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    let outing: Outing
    let picture: OutingPicture?
    @State private var colours: [HSL] = []

    var body: some View {
        let shades = PictureColours.backdrop(colours.isEmpty ? fallback : colours, dark: scheme == .dark)
        let first = shades.first?.color ?? .clear
        let second = shades.dropFirst().first?.color ?? first
        let third = shades.dropFirst(2).first?.color ?? second
        ZStack {
            LinearGradient(colors: [first, second], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [third, third.opacity(0)], center: .topTrailing, startRadius: 0, endRadius: 520)
        }
        .mask {
            LinearGradient(
                stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5), .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .task(id: picture.map { ObjectIdentifier($0.image) }) {
            guard let image = picture?.image else {
                colours = []
                return
            }
            colours = await Task.detached(priority: .utility) { PictureColours.dominant(image) }.value
        }
    }

    private var fallback: [HSL] {
        let title = TitleColours(title: outing.title)
        return [title.glow, title.start, title.end].map { HSL(hue: $0.hue, saturation: 0.6, lightness: 0.5) }
    }
}
