import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

/// A title as a page: the artwork large across the top with the actions on
/// glass, then the story beside Op Dobby, the trailer when it plays, and
/// the scores, production, cast and makers, seasons, more like it and the
/// reviews.
struct TitlePage: View {
    @Environment(LumosModel.self) private var model
    let ref: TitleRef
    var focused: FocusState<LumosModel.Focus?>.Binding

    var body: some View {
        Group {
            if let detail = model.detail, detail.ref == ref {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Hero(detail: detail)
                        VStack(alignment: .leading, spacing: 0) {
                            if let player = model.player, player.ref == ref { Trailer(player: player) }
                            HStack(alignment: .top, spacing: 28) {
                                Story(detail: detail)
                                OnDobby(detail: detail).frame(width: 320)
                            }
                            Sections(detail: detail)
                        }
                        .padding(EdgeInsets(top: 20, leading: 28, bottom: 36, trailing: 28))
                    }
                }
                .ignoresSafeArea(edges: .top)
            } else if let summary = model.summary(ref) {
                // The card's own facts while the page loads, so nothing is blank.
                VStack(alignment: .leading, spacing: 12) {
                    Artwork(title: summary, style: .wide).frame(maxWidth: .infinity).frame(height: 360).clipped()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.title).font(.largeTitle).bold()
                        Text(summary.line).foregroundStyle(.secondary)
                        ProgressView().controlSize(.small)
                    }
                    .padding(.horizontal, 28)
                    Spacer()
                }
                .ignoresSafeArea(edges: .top)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model.detail?.title ?? model.summary(ref)?.title ?? "")
        .toolbar {
            if let detail = model.detail, detail.ref == ref, let url = detail.tmdbUrl.flatMap(URL.init(string:)) {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url, subject: Text(detail.title)) { Label("Deel", systemImage: "square.and.arrow.up") }
                }
            }
        }
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
            case "z": Task { await model.undo() }
            default: return .ignored
            }
        }
        return .handled
    }
}

// MARK: The artwork with the actions

/// The still large across the top, like the TV app; the title and the
/// buttons on glass, drawn dark so they read on any picture.
private struct Hero: View {
    @Environment(LumosModel.self) private var model
    let detail: TitleDetail
    @State private var seasons: Set<Int> = [1]

    var body: some View {
        let url = (detail.stills.first ?? detail.backdrop).flatMap(URL.init(string:))
        CachedImage(url: url, maxPixels: 1600) { Placeholder(title: detail.summary, style: .wide, showsTitle: false) }
            .frame(maxWidth: .infinity)
            .frame(height: 460)
            .clipped()
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.78), location: 1)], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(detail.title).font(.largeTitle).bold().lineLimit(2)
                    Text(facts).font(.callout).foregroundStyle(.secondary)
                    actions.padding(.top, 6)
                }
                .padding(28)
                .environment(\.colorScheme, .dark)
            }
            .accessibilityElement(children: .contain)
    }

    private var facts: String {
        let summary = detail.summary
        var parts: [String?] = [summary.kind, detail.year.map(String.init), summary.length, detail.genres.prefix(3).joined(separator: ", ")]
        if detail.mediaType == .tv, let episodes = detail.episodes { parts.append("\(episodes) afleveringen") }
        if let language = detail.language { parts.append(language) }
        if let status = detail.statusLabel { parts.append(status) }
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var list: String { model.listName.lowercased() }
    private var held: Bool { detail.availability.held }

    private var seasonTotal: Int? {
        guard detail.mediaType == .tv, !detail.onList, let total = detail.seasons, total > 1 else { return nil }
        return total
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if held, model.canWatch {
                Button { Task { await model.watch(detail.ref) } } label: {
                    Label(watchLabel, systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .help("Kijk op de tv (K)")
                .popover(isPresented: Binding(
                    get: { model.screenMenu == detail.ref },
                    set: { if !$0 { model.screenMenu = nil } }
                ), arrowEdge: .bottom) {
                    ScreenChoice()
                }
            }
            listButton
            Button {
                model.focus = .inspector
                model.reasonMenu = detail.ref
            } label: {
                Text("Niet nu")
            }
            .buttonStyle(.glass)
            .help("Niet nu, reden optioneel (N)")
            .popover(isPresented: Binding(
                get: { model.reasonMenu == detail.ref && model.focus == .inspector },
                set: { if !$0 { model.reasonMenu = nil } }
            ), arrowEdge: .bottom) {
                ReasonMenu(ref: detail.ref)
            }
            if detail.trailer != nil {
                Button("Trailer", systemImage: model.player?.ref == detail.ref ? "stop.fill" : "play.rectangle") {
                    if model.player?.ref == detail.ref { model.stopTrailer() } else { Task { await model.playTrailer(detail.ref) } }
                }
                .buttonStyle(.glass)
                .help("Streamt pas na deze klik; er wordt niets bewaard (T)")
            }
            if let total = seasonTotal {
                SeasonMenu(total: total, selection: $seasons) {
                    Text(SeasonMenu<Text>.text(seasons, total: total))
                }
                .buttonStyle(.glass)
                .fixedSize()
                .onChange(of: detail.ref) { seasons = [1] }
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder private var listButton: some View {
        let button = Button {
            Task { await model.toggleList(detail.ref, seasons: seasonTotal == nil ? nil : seasons.sorted()) }
        } label: {
            Label(detail.onList ? "Op \(list)" : held ? "Zet op \(list)" : "Ja, op \(list)", systemImage: detail.onList ? "bookmark.fill" : "bookmark")
        }
        .help(detail.onList ? "Staat op \(list); nog een keer haalt hem eraf (J)" : "Ja: zet op \(list) (J)")
        .accessibilityIdentifier("lumos.approve.list")
        if held || detail.onList {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.glassProminent)
        }
    }

    /// "Kijken", or where the household stopped.
    private var watchLabel: String {
        if let resume = model.watchInfo?.resume ?? detail.library?.server?.watched?.resume {
            if let episode = resume.episode { return "Kijk \(episode.label)" }
            if resume.positionSeconds > 0 { return "Verder kijken" }
        }
        return "Kijken"
    }
}

/// K with several screens open: which one.
private struct ScreenChoice: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Op welk scherm?").font(.headline)
            ForEach(model.watchInfo?.screens ?? []) { screen in
                Button(screen.name, systemImage: "tv") { Task { await model.play(on: screen) } }
                    .buttonStyle(.borderless)
            }
        }
        .padding(14)
    }
}

/// The trailer, streamed only after a click; nothing is kept.
private struct Trailer: View {
    @Environment(LumosModel.self) private var model
    let player: TrailerPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TrailerPlayerView(playback: player, origin: model.connection?.serverURL)
                .id(player.ref)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: 820)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                Text(player.statusText)
                    .accessibilityIdentifier("lumos.player.status")
                Spacer()
                if let url = player.trailer.sourceURL {
                    Link(destination: url) { Label("Groot beeld bij de bron", systemImage: "arrow.up.right.square") }
                }
                Button("Stop", systemImage: "stop.fill") { model.stopTrailer() }
                    .buttonStyle(.bordered)
                    .help("Stop de trailer (Esc)")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 820)
        }
        .padding(.bottom, 24)
    }
}

// MARK: The story

private struct Story: View {
    @Environment(LumosModel.self) private var model
    let detail: TitleDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let tagline = detail.tagline { Text(tagline).font(.title3).italic().foregroundStyle(.secondary) }
            if let synopsis = detail.synopsis {
                Text(synopsis).font(.body).lineSpacing(3).textSelection(.enabled)
            }
            if let pass = detail.pass {
                HStack(spacing: 8) {
                    Label(pass.kind == .seen ? "Al gezien" : "Overgeslagen\(pass.reason.map { ": \($0)" } ?? "")", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                    Button("Terugzetten") { Task { await model.restore(verdictId: pass.id, title: detail.title) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .font(.callout)
            }
            if detail.match != nil || (model.scope == .shared && detail.onMine && !detail.onShared) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Waarom voorgesteld").font(.headline)
                    if let match = detail.match { Text(match).foregroundStyle(.secondary) }
                    if model.scope == .shared, detail.onMine, !detail.onShared {
                        Text("Staat op jouw eigen lijst; samen nog niet.").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
            labels
            tune
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var labels: some View {
        FlowLayout(spacing: 6) {
            ForEach(detail.genres + detail.traits, id: \.self) { word in
                Button(word) { model.query = word }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Zoek \(word)")
            }
        }
    }

    private var tune: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Voorstellen bijstellen").font(.headline)
            HStack(spacing: 8) {
                Toggle("Meer zoals dit", systemImage: "hand.thumbsup", isOn: Binding(
                    get: { detail.taste?.kind == .moreLikeThis }, set: { _ in Task { await model.taste(.moreLikeThis, detail.ref) } }))
                Toggle("Minder zoals dit", systemImage: "hand.thumbsdown", isOn: Binding(
                    get: { detail.taste?.kind == .lessLikeThis }, set: { _ in Task { await model.taste(.lessLikeThis, detail.ref) } }))
            }
            .toggleStyle(.button)
            Text("Geldt voor \(model.scope == .shared ? "samen" : model.myName). Al gezien telt nooit als afkeer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Op Dobby

/// What is on Dobby: size, added, seen together and by you, the picture,
/// who manages it, and Verwijderen. While it downloads, how far; before
/// that, what Ja does.
private struct OnDobby: View {
    @Environment(LumosModel.self) private var model
    let detail: TitleDetail

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let library = detail.library {
                    Text("Op Dobby").font(.headline)
                    held(library)
                } else if detail.availability.held {
                    Text("Op Dobby").font(.headline)
                    Text("De mediaserver geeft geen grootte of datum.").font(.callout).foregroundStyle(.secondary)
                } else if detail.download != nil || [.downloading, .importing, .requested, .waitingForRelease, .importProblem].contains(detail.availability) {
                    Text("Onderweg naar Dobby").font(.headline)
                    coming
                } else {
                    Text("Niet op Dobby").font(.headline)
                    Text(model.status?.requests == true ? "Ja zet de titel op de lijst en vraagt hem aan." : "Ja zet de titel op de lijst.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    request
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    @ViewBuilder private func held(_ library: LibraryInfo) -> some View {
        let item = ManageItem(
            title: detail.summary, download: nil, addedAt: library.addedAt, removable: library.removable,
            server: library.server, seen: detail.seen, spaceCandidate: nil)
        OnDobbyFacts(item: item)
        if let info = model.watchInfo {
            if info.web != nil {
                HStack {
                    Text(info.screens.isEmpty ? "Open Jellyfin op de tv om daar te kijken." : "Op \(info.screens.map(\.name).joined(separator: " of "))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Hier", systemImage: "safari") { model.watchHere(detail.ref) }
                        .buttonStyle(.bordered)
                        .help("Opent de pagina in Jellyfin in je browser (⇧⌘K)")
                }
            } else {
                Text("Jellyfin heeft deze titel niet gevonden.").font(.callout).foregroundStyle(.secondary)
            }
        }
        if model.canDelete {
            Button("Verwijderen…", systemImage: "trash", role: .destructive) {
                if let held = model.libraryItem(detail.ref) {
                    model.askDelete([held.id])
                } else {
                    model.deleteRequest = DeleteRequest(items: [item], kept: 0)
                }
            }
            .disabled(!library.removable)
            if !library.removable {
                Label(item.lockReason, systemImage: "lock.fill").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var coming: some View {
        if let download = detail.download {
            ProgressView(value: download.progress).accessibilityLabel("Gedownload")
            Text(["\(Int((download.progress * 100).rounded())) %", Eta.text(download.eta)].compactMap { $0 }.joined(separator: " · "))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text(detail.availability.label).font(.callout).foregroundStyle(.secondary)
        }
        request
    }

    @ViewBuilder private var request: some View {
        if let label = detail.request?.label {
            Text(label).font(.callout).foregroundStyle(detail.request?.status == .failed ? .red : .secondary)
        }
        if detail.request?.status == .failed {
            Button("Opnieuw proberen", systemImage: "arrow.clockwise") { Task { await model.retryRequest(detail.ref) } }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("lumos.approve.retryRequest")
        }
    }
}

// MARK: Below the fold

/// Scores, money, cast, makers, seasons, more like it and the reviews.
private struct Sections: View {
    @Environment(LumosModel.self) private var model
    let detail: TitleDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                InfoSection("Scores per bron") { ScoresView(scores: detail.scores, fixture: detail.dataOrigin == .fixture) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                if detail.budget != nil || detail.revenue != nil || !(detail.studios ?? []).isEmpty || detail.collection != nil {
                    InfoSection("Productie") { MoneyView(detail: detail) }
                        .frame(width: 320, alignment: .leading)
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
        }
    }
}

/// What a film cost and made, as the source reports it, and who made it.
private struct MoneyView: View {
    let detail: TitleDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let budget = detail.budget { LabeledContent("Budget", value: Money.short(budget)) }
            if let revenue = detail.revenue {
                LabeledContent("Opbrengst") {
                    HStack(spacing: 6) {
                        Text(Money.short(revenue)).monospacedDigit()
                        if let budget = detail.budget, budget > 0 {
                            let ratio = revenue / budget
                            Text(String(format: "%.1f×", ratio))
                                .font(.caption)
                                .foregroundStyle(ratio >= 2 ? .green : ratio >= 1 ? .secondary : .red)
                                .help("Opbrengst gedeeld door budget, wereldwijd aan de kassa")
                        }
                    }
                }
            }
            if let studios = detail.studios, !studios.isEmpty {
                LabeledContent(detail.mediaType == .tv ? "Zender" : "Studio", value: studios.joined(separator: ", "))
            }
            if let collection = detail.collection { LabeledContent("Reeks", value: collection.name) }
            if let date = detail.releaseDate { LabeledContent(detail.mediaType == .tv ? "Eerste" : "Uitgebracht", value: date) }
            if let last = detail.lastAired { LabeledContent("Laatste", value: last) }
        }
        .textSelection(.enabled)
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
                            Face(person: person, size: 76)
                            Text(person.name).font(.caption).bold().lineLimit(2).multilineTextAlignment(.center)
                            if let part = person.part {
                                Text(part).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                            }
                        }
                        .frame(width: 96)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Alles van \(person.name)")
                    .accessibilityLabel([person.name, person.part].compactMap { $0 }.joined(separator: ", "))
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
                    .font(.title2).bold().foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.separator))
        .accessibilityHidden(true)
    }
}

private struct SeasonsView: View {
    let seasons: [SeasonSummary]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(seasons) { season in
                HStack(spacing: 10) {
                    CachedImage(url: season.poster.flatMap(URL.init(string:)), maxPixels: 185) { Rectangle().fill(.quaternary) }
                        .frame(width: 30, height: 45)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .accessibilityHidden(true)
                    Text(season.name)
                    Spacer()
                    Text([season.episodes.map { "\($0) afl." }, season.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                if season.id != seasons.last?.id { Divider() }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3).bold().accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.top, 28)
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
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(scores.enumerated()), id: \.offset) { index, score in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(score.source)
                                if let label = score.label { Text(label).font(.caption).foregroundStyle(.secondary) }
                            }
                            .frame(width: 130, alignment: .leading)
                            Text(score.valueText).font(.headline).monospacedDigit()
                            Spacer()
                            Text([score.votesText, score.asOf].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let url = score.url.flatMap(URL.init(string:)) {
                                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                                    .help("Bron openen")
                                    .accessibilityLabel("\(score.source) openen")
                            }
                        }
                        .padding(.vertical, 6)
                        if index < scores.count - 1 { Divider() }
                    }
                }
            }
            .frame(maxWidth: 580)
            if fixture, scores.contains(where: { $0.source.hasSuffix("(test)") }) {
                Text("(test) = verzonnen score bij een verzonnen titel.").font(.caption).foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snippets, id: \.url) { snippet in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("“\(snippet.quote)”").font(.body).italic().textSelection(.enabled)
                            HStack(spacing: 6) {
                                Text(snippet.source).bold()
                                if let author = snippet.author { Text(author) }
                                if let url = URL(string: snippet.url) { Link("Volledige review", destination: url) }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: 660)
                }
                Text("Korte fragmenten in de taal van de bron. De volledige review kan spoilers bevatten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
