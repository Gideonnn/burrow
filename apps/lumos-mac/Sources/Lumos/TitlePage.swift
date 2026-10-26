import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

/// A title as a page over the rows: the trailer or the still beside the
/// facts and the actions, then the story, the scores, what it cost and
/// made, the reviews, the cast and makers with their own pages, the
/// seasons, and more like it.
struct TitlePage: View {
    @Environment(LumosModel.self) private var model
    let ref: TitleRef
    var focused: FocusState<LumosModel.Focus?>.Binding

    var body: some View {
        ZStack {
            if let detail = model.detail, detail.ref == ref {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Backdrop(detail: detail)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top, spacing: 24) {
                                Stage(detail: detail).frame(width: 520)
                                Facts(detail: detail)
                            }
                            Sections(detail: detail)
                        }
                        .padding(EdgeInsets(top: 18, leading: 24, bottom: 36, trailing: 24))
                    }
                }
            } else if let summary = model.summary(ref) {
                // The card's own facts while the page loads, so nothing is blank.
                VStack(alignment: .leading, spacing: 12) {
                    Artwork(title: summary, style: .wide).frame(width: 520, height: 292.5).clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(summary.title).font(.system(size: 26, weight: .bold))
                    Text(summary.line).foregroundStyle(.secondary)
                    ProgressView().controlSize(.small)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused(focused, equals: .inspector)
        .focusEffectDisabled()
        .onExitCommand { model.escape() }
        .onKeyPress(phases: .down) { press in handle(press) }
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
        case .space: model.toggleInspector()
        default:
            switch press.characters.lowercased() {
            case "j": Task { await model.toggleList() }
            case "n": model.reasonMenu = model.inspected
            case "t": Task { await model.playTrailer() }
            case "k": Task { await model.watch() }
            case "z": Task { await model.undo() }
            default: return .ignored
            }
        }
        return .handled
    }
}

/// The still across the top, faded into the page, so the page has a mood
/// before anything is read.
private struct Backdrop: View {
    let detail: TitleDetail

    var body: some View {
        let url = (detail.stills.first ?? detail.backdrop).flatMap(URL.init(string:))
        CachedImage(url: url, maxPixels: 1280) { Placeholder(title: detail.summary, style: .wide, showsTitle: false) }
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: BurrowColor.plaster.opacity(0.6), location: 0.6), .init(color: BurrowColor.plaster, location: 1)],
                    startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.title).font(.system(size: 30, weight: .bold)).lineLimit(2)
                    if let tagline = detail.tagline { Text(tagline).font(.system(size: 13)).italic().foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
            }
            .accessibilityHidden(true)
    }
}

// MARK: The trailer and the stills

struct Stage: View {
    @Environment(LumosModel.self) private var model
    let detail: TitleDetail
    @State private var showStills = false
    @State private var still = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                if showStills, let url = URL(string: detail.stills[min(still, detail.stills.count - 1)]) {
                    CachedImage(url: url, maxPixels: 1280) { Color.black }
                } else if let player = model.player, player.ref == detail.ref {
                    TrailerPlayerView(playback: player, origin: model.connection?.serverURL)
                        .id(detail.ref)
                } else {
                    Artwork(title: detail.summary, style: .wide, maxPixels: 1280, placeholderTitle: false)
                    if detail.trailer != nil {
                        LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .bottom, endPoint: .center)
                        Button {
                            Task { await model.playTrailer(detail.ref) }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Color(white: 0.12))
                                    .frame(width: 54, height: 54)
                                    .background(Circle().fill(.white.opacity(0.92)))
                                    .shadow(color: .black.opacity(0.35), radius: 9, y: 3)
                                Text("Trailer afspelen").font(.caption.weight(.semibold)).foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Streamt pas na deze klik; er wordt niets bewaard (T)")
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                if !detail.stills.isEmpty {
                    Picker("Media", selection: $showStills) {
                        Label("Trailer", systemImage: "play").tag(false)
                        Label("Beelden", systemImage: "photo").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: showStills) { if showStills { model.stopTrailer() } }
                }
                StageBar(detail: detail, showStills: showStills)
            }
        }
    }
}

struct StageBar: View {
    @Environment(LumosModel.self) private var model
    let detail: TitleDetail
    let showStills: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if showStills {
                    Text(detail.stillsCredit ?? "Beelden van de bron")
                } else if let player = model.player, player.ref == detail.ref {
                    Text(player.statusText).accessibilityIdentifier("lumos.player.status")
                } else if let trailer = detail.trailer {
                    switch trailer {
                    case .youtube: Text("Streamt na klik via youtube-nocookie.com · \(trailer.publisher) · niets lokaal")
                    case let .direct(_, _, publisher, _, license, _):
                        Text("Stream van \(publisher)\(license.map { " · \($0)" } ?? "") · niets lokaal")
                    }
                } else {
                    Text("Geen trailer gekoppeld")
                }
            }
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.player?.ref == detail.ref {
                Button("Stop", systemImage: "stop.fill") { model.stopTrailer() }
                    .controlSize(.small)
                    .help("Stop de trailer (Esc)")
            }
            if let url = detail.trailer?.sourceURL, !showStills {
                Link(destination: url) { Label("Groot beeld bij bron", systemImage: "arrow.up.right.square") }
                    .help("Opent de bron voor volledig scherm of een betere kwaliteit")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

// MARK: Facts and actions

struct Facts: View {
    @Environment(LumosModel.self) private var model
    let detail: TitleDetail
    @State private var seasons: Set<Int> = [1]

    private var list: String { model.scope == .shared ? "onze lijst" : "jouw lijst" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            meta
            actions.padding(.top, 14)
            progress.padding(.top, 8)
            if let pass = detail.pass {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                    Text(pass.kind == .seen ? "Al gezien" : "Overgeslagen\(pass.reason.map { ": \($0)" } ?? "")")
                    Button("Terugzetten") { Task { await model.restore(verdictId: pass.id, title: detail.title) } }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }
            if detail.match != nil || (model.scope == .shared && detail.onMine) {
                InfoSection("Waarom voorgesteld") {
                    VStack(alignment: .leading, spacing: 3) {
                        if let match = detail.match { Text(match) }
                        if model.scope == .shared, detail.onMine, !detail.onShared { Text("Staat op jouw eigen lijst; samen nog niet.") }
                    }
                    .font(.callout)
                }
            }
            if let synopsis = detail.synopsis {
                Text(synopsis)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.top, 14)
            }
            labels.padding(.top, 12)
            InfoSection("Voorstellen bijstellen") { tune }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meta: some View {
        let summary = detail.summary
        return FlowLayout(spacing: 10) {
            Text(summary.kind)
            if let year = detail.year { Text(String(year)) }
            if let length = summary.length { Text(length) }
            if detail.mediaType == .tv, let episodes = detail.episodes { Text("\(episodes) afleveringen") }
            if let language = detail.language { Text(language) }
            if let status = detail.statusLabel { Text(status) }
            if let original = detail.originalTitle { Text("‘\(original)’").italic() }
            if detail.availability == .available {
                Label("In Jellyfin", systemImage: "checkmark.circle.fill").foregroundStyle(BurrowColor.success)
            } else {
                Text(detail.availability.label)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private var seasonTotal: Int? {
        guard detail.mediaType == .tv, !detail.onList, let total = detail.seasons, total > 1 else { return nil }
        return total
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    Task { await model.toggleList(detail.ref, seasons: seasonTotal == nil ? nil : seasons.sorted()) }
                } label: {
                    Label(detail.onList ? "Op \(list)" : "Op \(list) zetten", systemImage: detail.onList ? "checkmark" : "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(detail.onList ? BurrowColor.success : BurrowColor.lumos)
                .help(detail.onList ? "Staat op \(list); nog een keer haalt hem eraf (J)" : "Ja: zet op \(list) (J)")
                .accessibilityIdentifier("lumos.approve.list")
                Button {
                    model.focus = .inspector
                    model.reasonMenu = detail.ref
                } label: {
                    Label("Niet nu", systemImage: "chevron.down")
                }
                .help("Niet nu, reden optioneel (N)")
                .popover(isPresented: Binding(
                    get: { model.reasonMenu == detail.ref && model.focus == .inspector },
                    set: { if !$0 { model.reasonMenu = nil } }
                ), arrowEdge: .bottom) {
                    ReasonMenu(ref: detail.ref)
                }
                if detail.trailer != nil, model.player?.ref != detail.ref {
                    Button("Trailer", systemImage: "play") { Task { await model.playTrailer(detail.ref) } }
                        .help("Streamt pas na deze klik (T)")
                }
            }
            if watchable { watchRow }
            if let total = seasonTotal {
                HStack(spacing: 6) {
                    Text("Seizoenen").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    SeasonMenu(total: total, selection: $seasons) {
                        Text(SeasonMenu<Text>.text(seasons, total: total))
                    }
                    .fixedSize()
                    .onChange(of: detail.ref) { seasons = [1] }
                }
            }
        }
    }

    private var watchable: Bool {
        model.canWatch && (detail.availability == .available || detail.availability == .partiallyAvailable)
    }

    @ViewBuilder private var watchRow: some View {
        HStack(spacing: 6) {
            Text("Kijken").font(.system(size: 11.5)).foregroundStyle(.secondary)
            if let info = model.watchInfo {
                if info.web == nil {
                    Text("Niet gevonden in Jellyfin").font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    screenControl(info)
                    Button("Hier", systemImage: "safari") { model.watchHere(detail.ref) }
                        .help("Opent de pagina in Jellyfin in je browser (⇧⌘K)")
                    if let episode = info.episode {
                        Text(episode.label).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .popover(isPresented: Binding(
            get: { model.screenMenu == detail.ref },
            set: { if !$0 { model.screenMenu = nil } }
        ), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.watchInfo?.screens ?? []) { screen in
                    Button(screen.name) { Task { await model.play(on: screen, detail.ref) } }
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder private func screenControl(_ info: WatchInfo) -> some View {
        switch info.screens.count {
        case 0:
            Button("Op de tv", systemImage: "tv") {}
                .disabled(true)
                .help("Open Jellyfin op de tv; dan start Lumos hem daar (K)")
        case 1:
            Button { Task { await model.play(on: info.screens[0], detail.ref) } } label: {
                Label("Op \(info.screens[0].name)", systemImage: "tv")
            }
            .help("Start op de tv (K)")
        default:
            Menu {
                ForEach(info.screens) { screen in
                    Button(screen.name) { Task { await model.play(on: screen, detail.ref) } }
                }
            } label: {
                Label("Op de tv", systemImage: "tv")
            }
            .fixedSize()
        }
    }

    @ViewBuilder private var progress: some View {
        let request = detail.request
        if detail.download != nil || request?.label != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let download = detail.download {
                    HStack(spacing: 8) {
                        ProgressView(value: download.progress).frame(maxWidth: 180)
                        Text("Gedownload \(Int((download.progress * 100).rounded())) %").monospacedDigit()
                    }
                }
                if let label = request?.label, detail.availability != .available {
                    Text(label).foregroundStyle(request?.status == .failed ? BurrowColor.danger : .secondary)
                }
                if request?.status == .failed {
                    Button("Opnieuw proberen", systemImage: "arrow.clockwise") {
                        Task { await model.retryRequest(detail.ref) }
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("lumos.approve.retryRequest")
                }
            }
            .font(.system(size: 11.5))
        }
    }

    private var labels: some View {
        FlowLayout(spacing: 5) {
            ForEach(detail.genres, id: \.self) { genre in
                Button(genre) { model.query = genre }.buttonStyle(LabelStyle(genre: true)).help("Zoek genre \(genre)")
            }
            ForEach(detail.traits, id: \.self) { trait in
                Button(trait) { model.query = trait }.buttonStyle(LabelStyle(genre: false)).help("Zoek kenmerk \(trait)")
            }
        }
    }

    private var tune: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Meer zoals dit", systemImage: "hand.thumbsup") { Task { await model.taste(.moreLikeThis, detail.ref) } }
                    .buttonStyle(ChipStyle(on: detail.taste?.kind == .moreLikeThis))
                Button("Minder zoals dit", systemImage: "hand.thumbsdown") { Task { await model.taste(.lessLikeThis, detail.ref) } }
                    .buttonStyle(ChipStyle(on: detail.taste?.kind == .lessLikeThis))
            }
            Text("Geldt voor \(model.scope == .shared ? "samen" : model.myName), op kenmerken van deze titel. ‘Al gezien’ telt nooit als afkeer.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: Below the fold

/// Scores, money, reviews, cast, makers, seasons and more like it.
private struct Sections: View {
    @Environment(LumosModel.self) private var model
    let detail: TitleDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                InfoSection("Scores per bron") { ScoresView(scores: detail.scores, fixture: detail.dataOrigin == .fixture) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                if detail.budget != nil || detail.revenue != nil || !(detail.studios ?? []).isEmpty || detail.collection != nil {
                    InfoSection("Productie") { MoneyView(detail: detail) }
                        .frame(width: 300, alignment: .leading)
                }
            }
            if let cast = detail.cast, !cast.isEmpty {
                InfoSection("Cast") { PeopleRow(people: cast) }
            }
            if let crew = detail.crew, !crew.isEmpty {
                InfoSection(detail.mediaType == .tv ? "Makers" : "Regie en scenario") { PeopleRow(people: crew) }
            }
            if let seasons = detail.seasonList, !seasons.isEmpty {
                InfoSection("Seizoenen") { SeasonsView(seasons: seasons) }
            }
            if !model.similar.isEmpty {
                InfoSection("Meer zoals dit") {
                    Shelf(row: TitleRow(key: "similar", title: "", subtitle: nil, style: .poster, items: model.similar, empty: nil))
                        .padding(.horizontal, -24)
                }
            }
            InfoSection("Reviews") { SnippetsView(snippets: detail.snippets) }
            if let tmdb = detail.tmdbUrl.flatMap(URL.init(string:)) {
                Link("TMDB-pagina", destination: tmdb).font(.caption).padding(.top, 14)
            }
        }
    }
}

/// What a film cost and made, as the source reports it, and who made it.
private struct MoneyView: View {
    let detail: TitleDetail

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            if let budget = detail.budget {
                GridRow { key("Budget"); Text(Money.short(budget)).monospacedDigit() }
            }
            if let revenue = detail.revenue {
                GridRow {
                    key("Opbrengst")
                    HStack(spacing: 6) {
                        Text(Money.short(revenue)).monospacedDigit()
                        if let budget = detail.budget, budget > 0 {
                            let ratio = revenue / budget
                            Text(String(format: "%.1f×", ratio))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ratio >= 2 ? BurrowColor.success : ratio >= 1 ? Color.secondary : BurrowColor.danger)
                                .help("Opbrengst gedeeld door budget, wereldwijd aan de kassa")
                        }
                    }
                }
            }
            if let studios = detail.studios, !studios.isEmpty {
                GridRow(alignment: .firstTextBaseline) { key(detail.mediaType == .tv ? "Zender" : "Studio"); Text(studios.joined(separator: ", ")) }
            }
            if let collection = detail.collection {
                GridRow { key("Reeks"); Text(collection.name) }
            }
            if let date = detail.releaseDate {
                GridRow { key(detail.mediaType == .tv ? "Eerste" : "Uitgebracht"); Text(date) }
            }
            if let last = detail.lastAired {
                GridRow { key("Laatste"); Text(last) }
            }
        }
        .font(.system(size: 12.5))
        .textSelection(.enabled)
    }

    private func key(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }
}

/// Faces in a row; a click opens the person's page.
private struct PeopleRow: View {
    @Environment(LumosModel.self) private var model
    let people: [CastMember]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(people) { person in
                    Button { model.openPerson(person.id, name: person.name) } label: {
                        VStack(spacing: 6) {
                            Face(person: person, size: 72)
                            Text(person.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                            if let part = person.part {
                                Text(part).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                            }
                        }
                        .frame(width: 92)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Alles van \(person.name)")
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// A person's photo, or their initials.
struct Face: View {
    let person: CastMember
    var size: CGFloat

    var body: some View {
        CachedImage(url: person.photo.flatMap(URL.init(string:)), maxPixels: 185) {
            ZStack {
                TileColours(person.name).start
                Text(person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                    .font(.system(size: size * 0.32, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.black.opacity(0.08)))
    }
}

private struct SeasonsView: View {
    let seasons: [SeasonSummary]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(seasons) { season in
                HStack(spacing: 10) {
                    CachedImage(url: season.poster.flatMap(URL.init(string:)), maxPixels: 185) { Color.secondary.opacity(0.2) }
                        .frame(width: 30, height: 45)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(season.name).font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Text([season.episodes.map { "\($0) afl." }, season.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                if season.id != seasons.last?.id { Divider() }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(.secondary)
            content
        }
        .padding(.top, 22)
    }
}

struct LabelStyle: ButtonStyle {
    var genre: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: genre ? .medium : .regular))
            .foregroundStyle(genre ? AnyShapeStyle(BurrowColor.lumos) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(genre ? BurrowColor.lumos.opacity(0.13) : BurrowColor.linen))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Every score with its source, scale and number of votes, or a line that
/// there are none: a missing source is never filled in from another.
struct ScoresView: View {
    let scores: [Score]
    let fixture: Bool

    var body: some View {
        if scores.isEmpty {
            Text("Nog geen scores van een bron.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(scores.enumerated()), id: \.offset) { index, score in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(score.source).font(.system(size: 12, weight: .medium))
                            if let label = score.label { Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                        }
                        .frame(width: 120, alignment: .leading)
                        Text(score.valueText).font(.system(size: 13.5, weight: .semibold)).monospacedDigit()
                        Spacer()
                        Text([score.votesText, score.asOf].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let url = score.url.flatMap(URL.init(string:)) {
                            Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("Bron openen")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    if index < scores.count - 1 { Divider() }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BurrowColor.hairline))
            .frame(maxWidth: 560)
            if fixture, scores.contains(where: { $0.source.hasSuffix("(test)") }) {
                Text("(test) = verzonnen score bij een verzonnen titel.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct SnippetsView: View {
    let snippets: [Snippet]

    var body: some View {
        if snippets.isEmpty {
            Text("Nog geen reviewfragmenten gekoppeld.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snippets, id: \.url) { snippet in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("“\(snippet.quote)”")
                            .font(.custom("New York", size: 12.5))
                            .textSelection(.enabled)
                        HStack(spacing: 6) {
                            Text(snippet.source).fontWeight(.semibold)
                            if let author = snippet.author { Text(author) }
                            if let url = URL(string: snippet.url) { Link("Volledige review", destination: url) }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: 640, alignment: .leading)
                    .background(BurrowColor.linen.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Korte fragmenten in de taal van de bron. De volledige review kan spoilers bevatten.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
