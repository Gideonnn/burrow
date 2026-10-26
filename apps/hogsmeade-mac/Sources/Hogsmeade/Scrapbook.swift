import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

/// A title as a page in a scrapbook over the wall: the picture with tape, a
/// score sticker, the facts as pills, the synopsis on paper, scores on a
/// receipt and reviews as clippings. Same keys as Lumos's inspector, plus
/// left and right for the previous and next poster.
struct Scrapbook: View {
    @Environment(LumosModel.self) private var model
    var focused: FocusState<LumosModel.Focus?>.Binding

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            Dots().ignoresSafeArea()
            if let detail = model.detail, detail.ref == model.inspected {
                ScrollView {
                    HStack(alignment: .top, spacing: 36) {
                        PhotoColumn(detail: detail)
                            .frame(width: 500)
                        FactsColumn(detail: detail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 48)
                    .padding(.top, 70)
                    .padding(.bottom, 60)
                }
                .id(detail.ref)
            } else {
                ProgressView().controlSize(.large).tint(Palette.violet)
            }
            VStack {
                HStack {
                    Spacer().frame(width: 72)
                    Button {
                        model.closeInspector()
                    } label: {
                        Label(backLabel, systemImage: "chevron.left").pill(.white, Palette.violet, height: 32).font(.round(13, .heavy))
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Terug naar de wand (Esc)")
                    Spacer()
                    if let summary = model.summary(model.inspected ?? TitleRef(mediaType: .movie, tmdbId: 0)), summary.pass == nil {
                        Text("← → volgende poster").font(.round(12, .bold)).foregroundStyle(Palette.faintOnCream)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused(focused, equals: .inspector)
        .focusEffectDisabled()
        .onExitCommand { model.escape() }
        .onKeyPress(phases: .down) { press in handle(press) }
    }

    private var backLabel: String {
        switch model.page {
        case .discover: "Vanavond"
        case .list: model.scope == .shared ? "Onze lijst" : "Jouw lijst"
        case .movies: "Films"
        case .series: "Series"
        case .available: "Jellyfin"
        case .taste: "Smaak"
        case .passed: "Overgeslagen"
        case .search: "Zoeken"
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) || press.modifiers.contains(.option) { return .ignored }
        if model.reasonMenu != nil {
            switch press.key {
            case .downArrow: model.moveReason(by: 1)
            case .upArrow: model.moveReason(by: -1)
            case .return: Task { await model.chooseReason() }
            case .escape: model.reasonMenu = nil
            default: return .ignored
            }
            return .handled
        }
        switch press.key {
        case .escape: model.escape()
        case .leftArrow: model.move(.left)
        case .rightArrow: model.move(.right)
        default:
            switch press.characters.lowercased() {
            case "j": Task { await model.toggleList() }
            case "n": model.reasonMenu = model.inspected
            case "t": Task { await model.playTrailer() }
            case "z": Task { await model.undo() }
            default: return .ignored
            }
        }
        return .handled
    }
}

/// The faint dot grid of the scrapbook paper.
struct Dots: View {
    var body: some View {
        Canvas { context, size in
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 2.4, height: 2.4))
            var y: CGFloat = 8
            while y < size.height {
                var x: CGFloat = 8
                while x < size.width {
                    context.fill(dot.offsetBy(dx: x, dy: y), with: .color(Color(hex: 0xE6DCC6)))
                    x += 22
                }
                y += 22
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: The photo

struct PhotoColumn: View {
    @Environment(LumosModel.self) private var model
    let detail: TitleDetail
    @State private var still: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    stage
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(.black)
                        .clipped()
                    caption
                }
                .padding(14)
                .background(.white)
                .shadow(color: Color(hex: 0x3C280A).opacity(0.18), radius: 20, y: 14)
                .rotationEffect(.degrees(-1.8))
                .overlay(alignment: .topLeading) { Tape(colour: Palette.mint, angle: -38).offset(x: -34, y: -8) }
                .overlay(alignment: .bottomTrailing) { Tape(colour: Palette.candy, angle: 32).offset(x: 44, y: 30) }
                if let score = detail.scores.first {
                    Sticker(size: 112, angle: 8) {
                        VStack(spacing: 2) {
                            Text(score.source).font(.round(11, .heavy)).lineLimit(1).minimumScaleFactor(0.7)
                            Text(score.scale == "percent" ? score.valueText : score.value.formatted(.number.precision(.fractionLength(1))))
                                .font(.round(30, .black)).kerning(-1)
                            if score.scale != "percent" { Text("van 10").font(.round(9, .bold)) }
                            if let votes = score.votesText { Text(votes).font(.round(9, .bold)).lineLimit(1).minimumScaleFactor(0.7) }
                        }
                        .padding(.horizontal, 8)
                    }
                    .offset(x: 28, y: -34)
                    .help("\(score.source)\(score.label.map { " (\($0))" } ?? "") op \(score.asOf)")
                }
            }
            .padding(.top, 20)
            StageBar(detail: detail, showStills: still != nil)
            if detail.stills.count > 1 {
                HStack(spacing: 8) {
                    ForEach(detail.stills.indices, id: \.self) { index in
                        Button { still = still == index ? nil : index } label: {
                            CachedImage(url: URL(string: detail.stills[index]), maxPixels: 200) { Color.gray }
                                .frame(width: 72, height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.violet, lineWidth: still == index ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !model.similar.isEmpty { SimilarShelf() }
        }
    }

    @ViewBuilder private var stage: some View {
        ZStack(alignment: .bottomLeading) {
            if let still, let url = URL(string: detail.stills[min(still, detail.stills.count - 1)]) {
                CachedImage(url: url, maxPixels: 1280) { Color.black }
            } else if let player = model.player, player.ref == detail.ref {
                TrailerPlayerView(playback: player, origin: model.connection?.serverURL)
                    .id(detail.ref)
            } else {
                Artwork(title: detail.summary, style: .wide, maxPixels: 1280, placeholderTitle: false)
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text([detail.summary.kind, detail.year.map(String.init), detail.summary.length].compactMap { $0 }.joined(separator: " · "))
                        .font(.round(12, .heavy)).kerning(1).textCase(.uppercase).foregroundStyle(.white.opacity(0.85))
                    Text(detail.title).poster(44).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                }
                .padding(18)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                if detail.trailer != nil {
                    Button {
                        Task { await model.playTrailer(detail.ref) }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(Palette.lemon))
                            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .help("Trailer, streamt pas na deze klik en bewaart niets (T)")
                }
            }
        }
        .onChange(of: still) { if still != nil { model.stopTrailer() } }
        .onChange(of: model.player) { if model.player != nil { still = nil } }
    }

    private var caption: some View {
        HStack {
            Text(detail.availability == .available ? "Staat in Jellyfin" : detail.availability.label)
                .foregroundStyle(detail.availability == .available ? Palette.onMint : Palette.mutedOnCream)
            Spacer()
            Text(detail.dataOrigin == .fixture ? "testgegevens" : "beeld van TMDB via Seerr")
                .foregroundStyle(Palette.faintOnCream)
        }
        .font(.round(13, .semibold))
        .padding(.top, 14)
        .padding(.bottom, 2)
    }
}

/// What plays or shows, and where it comes from; the trailer's own status, never guessed.
struct StageBar: View {
    @Environment(LumosModel.self) private var model
    let detail: TitleDetail
    let showStills: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if showStills {
                    Text(detail.stillsCredit ?? "Beelden van de bron")
                } else if let player = model.player, player.ref == detail.ref {
                    Text(player.statusText).accessibilityIdentifier("lumos.player.status")
                } else if let trailer = detail.trailer {
                    switch trailer {
                    case .youtube: Text("Trailer streamt na een klik via youtube-nocookie.com · \(trailer.publisher) · niets lokaal")
                    case let .direct(_, _, publisher, _, license, _): Text("Stream van \(publisher)\(license.map { " · \($0)" } ?? "") · niets lokaal")
                    }
                } else {
                    Text("Geen trailer gekoppeld. Hogsmeade toont nooit die van een andere titel.")
                }
            }
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.player?.ref == detail.ref {
                Button { model.stopTrailer() } label: { Label("Stop", systemImage: "stop.fill").pill(.white, Palette.ink, height: 28) }
                    .buttonStyle(.plain)
                    .help("Stop de trailer (Esc)")
            }
            if let url = detail.trailer?.sourceURL, !showStills {
                Link(destination: url) { Label("Groot bij de bron", systemImage: "arrow.up.right.square").pill(.white, Palette.violet, height: 28) }
                    .help("Opent de bron voor volledig scherm of een betere kwaliteit")
            }
        }
        .font(.round(12, .semibold))
        .foregroundStyle(Palette.mutedOnCream)
    }
}

struct SimilarShelf: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Meer zoals dit")
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(model.similar.enumerated()), id: \.element.id) { index, title in
                    Button {
                        model.open(title.ref, focusInside: true)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Artwork(title: title, style: .poster, maxPixels: 300)
                                .aspectRatio(2 / 3, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .shadow(color: Color(hex: 0x3C280A).opacity(0.18), radius: 10, y: 6)
                                .rotationEffect(.degrees(index.isMultiple(of: 2) ? -2 : 2))
                            Text(title.title).font(.round(12, .heavy)).foregroundStyle(Palette.ink).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: The facts

struct FactsColumn: View {
    @Environment(LumosModel.self) private var model
    let detail: TitleDetail
    @State private var seasons: Set<Int> = [1]

    private var list: String { model.scope == .shared ? "onze lijst" : "jouw lijst" }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(detail.title).font(.round(40, .black)).kerning(-1).foregroundStyle(Palette.ink).textSelection(.enabled)
                facts
            }
            actions
            progress
            if let match = detail.match ?? (model.scope == .shared && detail.onMine && !detail.onShared ? "Staat op jouw eigen lijst; samen nog niet." : nil) {
                Note(colour: Palette.lilac, angle: -0.8) {
                    Text("Waarom bovenaan").font(.round(11, .heavy)).kerning(0.8).textCase(.uppercase).foregroundStyle(Color(hex: 0x3B2360))
                    Text(match).font(.round(14, .semibold)).foregroundStyle(Palette.ink)
                }
            }
            if let synopsis = detail.synopsis {
                Note(colour: .white, angle: 0.6) {
                    Text(synopsis).font(.system(size: 14.5)).lineSpacing(4).foregroundStyle(Palette.ink).textSelection(.enabled)
                    if let language = detail.synopsisLanguage, language != "nl" {
                        Text("Samenvatting in de taal van de bron").font(.round(10.5, .semibold)).foregroundStyle(Palette.faintOnCream)
                    }
                }
            }
            labels
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Scores per bron")
                Receipt(scores: detail.scores, fixture: detail.dataOrigin == .fixture)
            }
            if !detail.snippets.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Knipsels")
                    ForEach(detail.snippets, id: \.url) { snippet in Clipping(snippet: snippet) }
                    Text("Korte fragmenten in de taal van de bron. De volledige review kan spoilers bevatten.")
                        .font(.round(10.5, .semibold)).foregroundStyle(Palette.faintOnCream)
                }
            }
            tune
            makers
            if let tmdb = detail.tmdbUrl.flatMap(URL.init(string:)) {
                Link("TMDB-pagina", destination: tmdb).font(.round(12, .bold)).foregroundStyle(Palette.violet)
            }
        }
    }

    private var facts: some View {
        HStack(spacing: 8) {
            Label(detail.summary.kind, systemImage: detail.mediaType == .tv ? "tv" : "film").pill(Palette.lemon, Palette.onLemon)
            if let year = detail.year { Text(String(year)).pill(.white, Palette.ink) }
            if let length = detail.summary.length { Label(length, systemImage: "clock").pill(.white, Palette.ink) }
            if let language = detail.language { Text(language).pill(.white, Palette.ink) }
            if detail.availability == .available {
                Label("In Jellyfin", systemImage: "checkmark").pill(Palette.mint, Palette.onMint)
            }
        }
        .shadow(color: Color(hex: 0x3C280A).opacity(0.1), radius: 6, y: 3)
    }

    /// A series with more than one season asks which; the pick goes with "Ja".
    private var seasonTotal: Int? {
        guard detail.mediaType == .tv, !detail.onList, let total = detail.seasons, total > 1 else { return nil }
        return total
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.toggleList(detail.ref, seasons: seasonTotal == nil ? nil : seasons.sorted()) }
            } label: {
                Label(detail.onList ? "Op \(list)!" : "Ja, op \(list)", systemImage: detail.onList ? "checkmark" : "plus")
                    .pill(detail.onList ? Palette.mint : Palette.lemon, detail.onList ? Palette.onMint : Palette.onLemon, height: 42)
                    .font(.round(15, .heavy))
            }
            .buttonStyle(.plain)
            .help(detail.onList ? "Staat op \(list); nog een keer haalt hem eraf (J)" : "Ja: zet op \(list) (J)")
            .accessibilityIdentifier("hogsmeade.approve.list")
            if let total = seasonTotal {
                SeasonMenu(total: total, selection: $seasons) {
                    Label(SeasonMenu<Text>.text(seasons, total: total), systemImage: "chevron.down")
                        .pill(.white, Palette.ink, height: 42).font(.round(14, .heavy))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .onChange(of: detail.ref) { seasons = [1] }
            }
            Button {
                model.focus = .inspector
                model.reasonMenu = detail.ref
            } label: {
                Label("Niet nu", systemImage: "chevron.down").pill(.white, Palette.ink, height: 42).font(.round(15, .heavy))
            }
            .buttonStyle(.plain)
            .help("Niet nu, reden optioneel (N)")
            .popover(isPresented: Binding(
                get: { model.reasonMenu == detail.ref && model.focus == .inspector },
                set: { if !$0 { model.reasonMenu = nil } }
            ), arrowEdge: .bottom) {
                ReasonSheet(ref: detail.ref)
            }
            if detail.trailer != nil, model.player?.ref != detail.ref {
                Button {
                    Task { await model.playTrailer(detail.ref) }
                } label: {
                    Label("Trailer", systemImage: "play.fill").pill(Palette.violet, .white, height: 42).font(.round(15, .heavy))
                }
                .buttonStyle(.plain)
                .help("Streamt pas na deze klik (T)")
            }
            if let pass = detail.pass {
                Button {
                    Task { await model.restore(verdictId: pass.id, title: detail.title) }
                } label: {
                    Label(pass.kind == .seen ? "Al gezien · terugzetten" : "Overgeslagen · terugzetten", systemImage: "arrow.uturn.backward")
                        .pill(Palette.lilac.opacity(0.5), Color(hex: 0x3B2360), height: 42).font(.round(13, .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .shadow(color: Color(hex: 0x3C280A).opacity(0.12), radius: 8, y: 4)
    }

    /// The request and the download, as far as Seerr and the download client know.
    @ViewBuilder private var progress: some View {
        let request = detail.request
        if detail.download != nil || request?.label != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let download = detail.download {
                    HStack(spacing: 10) {
                        ProgressView(value: download.progress).tint(Palette.violet).frame(maxWidth: 200)
                        Text("Gedownload \(Int((download.progress * 100).rounded())) %").monospacedDigit()
                    }
                }
                if let label = request?.label, detail.availability != .available {
                    Text(label.replacingOccurrences(of: "Lumos", with: "Hogsmeade"))
                        .foregroundStyle(request?.status == .failed ? Palette.hot : Palette.mutedOnCream)
                }
                if request?.status == .failed {
                    Button {
                        Task { await model.retryRequest(detail.ref) }
                    } label: {
                        Label("Opnieuw proberen", systemImage: "arrow.clockwise").pill(.white, Palette.violet, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("hogsmeade.approve.retryRequest")
                }
            }
            .font(.round(12.5, .semibold))
        }
    }

    private var labels: some View {
        FlowLayout(spacing: 6) {
            ForEach(detail.genres, id: \.self) { genre in
                Button { search(genre) } label: { Text(genre).pill(Palette.sky, Color(hex: 0x143557), height: 28) }
                    .buttonStyle(.plain).help("Zoek genre \(genre)")
            }
            ForEach(detail.traits, id: \.self) { trait in
                Button { search(trait) } label: { Text(trait).pill(.white, Palette.mutedOnCream, height: 28) }
                    .buttonStyle(.plain).help("Zoek kenmerk \(trait)")
            }
        }
    }

    /// A label or a name closes the page and searches the wall.
    private func search(_ text: String) {
        model.closeInspector(restoreFocus: false)
        model.query = text
    }

    private var tune: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Voorstellen bijstellen")
            HStack(spacing: 10) {
                TuneStamp(text: "Meer zoals dit", symbol: "hand.thumbsup.fill", on: detail.taste?.kind == .moreLikeThis, colour: Palette.mint) {
                    Task { await model.taste(.moreLikeThis, detail.ref) }
                }
                TuneStamp(text: "Minder zoals dit", symbol: "hand.thumbsdown.fill", on: detail.taste?.kind == .lessLikeThis, colour: Palette.hot) {
                    Task { await model.taste(.lessLikeThis, detail.ref) }
                }
            }
            Text("Geldt voor \(model.scope == .shared ? "samen" : model.myName), op kenmerken van deze titel. ‘Al gezien’ telt nooit als afkeer.")
                .font(.round(10.5, .semibold)).foregroundStyle(Palette.faintOnCream)
        }
    }

    private var makers: some View {
        let leads = detail.credits.filter { $0.role != "cast" }
        let cast = detail.credits.filter { $0.role == "cast" }
        return VStack(alignment: .leading, spacing: 10) {
            if !leads.isEmpty || !cast.isEmpty { SectionTitle("Makers") }
            if !leads.isEmpty { names(detail.mediaType == .tv ? "Maker" : "Regie", leads) }
            if !cast.isEmpty { names("Met", cast) }
        }
    }

    private func names(_ role: String, _ credits: [Credit]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(role).font(.round(12, .bold)).foregroundStyle(Palette.faintOnCream).frame(width: 44, alignment: .leading)
            FlowLayout(spacing: 6) {
                ForEach(credits, id: \.id) { credit in
                    Button { search(credit.name) } label: {
                        HStack(spacing: 6) {
                            PersonBadge(credit.name, size: 20)
                            Text(credit.name)
                        }
                        .pill(.white, Palette.ink, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Zoek alles met \(credit.name)")
                }
            }
        }
    }
}

struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.round(12, .heavy)).kerning(1).textCase(.uppercase).foregroundStyle(Palette.faintOnCream)
    }
}

/// A sheet of paper or a sticky note, slightly turned.
struct Note<Content: View>: View {
    var colour: Color
    var angle: Double
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colour)
            .shadow(color: Color(hex: 0x3C280A).opacity(0.14), radius: 12, y: 8)
            .rotationEffect(.degrees(angle))
    }
}

/// Every score with its source, scale and votes, printed like a receipt; a
/// missing source is never filled in from another.
struct Receipt: View {
    let scores: [Score]
    let fixture: Bool

    var body: some View {
        if scores.isEmpty {
            Text("Nog geen scores van een bron.").font(.round(13, .semibold)).foregroundStyle(Palette.mutedOnCream)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(scores.enumerated()), id: \.offset) { index, score in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(score.source).font(.round(13, .heavy))
                            if let label = score.label { Text(label).font(.round(10.5, .semibold)).foregroundStyle(Palette.faintOnCream) }
                        }
                        .frame(width: 130, alignment: .leading)
                        Text(score.valueText).font(.round(16, .black)).monospacedDigit()
                        Spacer()
                        Text([score.votesText, score.asOf].compactMap { $0 }.joined(separator: " · "))
                            .font(.round(11, .semibold)).foregroundStyle(Palette.faintOnCream)
                        if let url = score.url.flatMap(URL.init(string:)) {
                            Link(destination: url) { Image(systemName: "arrow.up.right.square") }.foregroundStyle(Palette.violet).help("Bron openen")
                        }
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    if index < scores.count - 1 {
                        Rectangle().fill(Color(hex: 0xEAE4F3)).frame(height: 1).padding(.horizontal, 10)
                    }
                }
            }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: Color(hex: 0x3C280A).opacity(0.14), radius: 12, y: 8)
            .rotationEffect(.degrees(-0.5))
            if fixture, scores.contains(where: { $0.source.hasSuffix("(test)") }) {
                Text("(test) = verzonnen score bij een verzonnen titel.").font(.round(10.5, .semibold)).foregroundStyle(Palette.faintOnCream)
            }
        }
    }
}

struct Clipping: View {
    let snippet: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("“\(snippet.quote)”").font(.custom("New York", size: 14)).foregroundStyle(Palette.ink).textSelection(.enabled)
            HStack(spacing: 6) {
                Text(snippet.source).font(.round(11, .heavy))
                if let author = snippet.author { Text(author).font(.round(11, .semibold)) }
                if let url = URL(string: snippet.url) { Link("Volledige review", destination: url).font(.round(11, .bold)).foregroundStyle(Palette.violet) }
            }
            .foregroundStyle(Palette.mutedOnCream)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .shadow(color: Color(hex: 0x3C280A).opacity(0.12), radius: 8, y: 5)
        .rotationEffect(.degrees(Double(snippet.url.count % 3) - 1))
    }
}

struct TuneStamp: View {
    let text: String
    let symbol: String
    let on: Bool
    let colour: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(text, systemImage: symbol)
                .poster(14)
                .kerning(0.6)
                .foregroundStyle(on ? .white : colour)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? colour : .clear))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(colour, lineWidth: 2.5))
                .rotationEffect(.degrees(on ? -3 : 0))
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25, bounce: 0.4), value: on)
    }
}
