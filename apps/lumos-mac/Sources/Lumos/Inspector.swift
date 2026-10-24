import BurrowUI
import LumosCore
import SwiftUI

/// The details on the right: the trailer or the stills, the facts, scores
/// per source, short reviews, taste and the makers. Scores and the reason a
/// title is proposed are kept apart.
struct InspectorView: View {
    @Environment(LumosModel.self) private var model
    var focused: FocusState<LumosModel.Focus?>.Binding

    var body: some View {
        // One stable container holds focus while the details load and change.
        ZStack {
            if let detail = model.detail, detail.ref == model.inspected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Stage(detail: detail)
                        Facts(detail: detail)
                    }
                    .padding(16)
                }
                .id(detail.ref)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused(focused, equals: .inspector)
        .focusEffectDisabled()
        // Esc reaches a view as the cancel command, not always as a key press.
        .onExitCommand { model.escape() }
        .onKeyPress(phases: .down) { press in
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
            if press.key == .escape {
                model.escape()
                return .handled
            }
            switch press.characters.lowercased() {
            case "j": Task { await model.toggleList() }
            case "n": model.reasonMenu = model.inspected
            case "t": Task { await model.playTrailer() }
            case "z": Task { await model.undo() }
            default: return .ignored
            }
            return .handled
        }
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
            if !detail.stills.isEmpty {
                Picker("Media", selection: $showStills) {
                    Label("Trailer", systemImage: "play").tag(false)
                    Label("Beelden \(detail.stills.count)", systemImage: "photo").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: showStills) { if showStills { model.stopTrailer() } }
            }
            ZStack {
                if showStills, let url = URL(string: detail.stills[min(still, detail.stills.count - 1)]) {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.black }
                } else if let player = model.player, player.ref == detail.ref {
                    TrailerPlayerView(playback: player, origin: model.connection?.serverURL)
                        .id(detail.ref)
                } else {
                    Artwork(title: detail.summary, style: .wide)
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
                    } else {
                        VStack(spacing: 4) {
                            Text("Geen trailer gekoppeld").font(.callout.weight(.semibold))
                            Text("Lumos toont nooit de trailer van een andere titel.").font(.caption)
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.55))
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if showStills, detail.stills.count > 1 {
                HStack(spacing: 6) {
                    ForEach(detail.stills.indices, id: \.self) { index in
                        Button { still = index } label: {
                            AsyncImage(url: URL(string: detail.stills[index])) { $0.resizable().scaledToFill() } placeholder: { Color.gray }
                                .frame(width: 62, height: 35)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .opacity(index == still ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            StageBar(detail: detail, showStills: showStills)
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
                    Text("Nog geen trailerbron gecontroleerd")
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
            } else if detail.trailer == nil, let tmdb = detail.tmdbUrl.flatMap(URL.init(string:)) {
                Link("Video’s op TMDB", destination: tmdb.appendingPathComponent("videos"))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

// MARK: Facts

struct Facts: View {
    @Environment(LumosModel.self) private var model
    let detail: TitleDetail

    private var list: String { model.scope == .shared ? "onze lijst" : "jouw lijst" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(detail.title)
                .font(.system(size: 21, weight: .bold))
                .textSelection(.enabled)
                .padding(.top, 16)
            meta.padding(.top, 5)
            actions.padding(.top, 14)
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
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.top, 14)
            }
            labels.padding(.top, 12)
            InfoSection("Scores per bron") { ScoresView(scores: detail.scores, fixture: detail.dataOrigin == .fixture) }
            InfoSection("Reviews") { SnippetsView(snippets: detail.snippets) }
            InfoSection("Voorstellen bijstellen") { tune }
            if !model.similar.isEmpty {
                InfoSection("Meer zoals dit") { similar }
            }
            InfoSection("Makers") { makers }
            if let tmdb = detail.tmdbUrl.flatMap(URL.init(string:)) {
                Link("TMDB-pagina", destination: tmdb).font(.caption).padding(.top, 8)
            }
        }
    }

    private var meta: some View {
        let summary = detail.summary
        return HStack(spacing: 10) {
            Text(summary.kind)
            if let year = detail.year { Text(String(year)) }
            if let length = summary.length { Text(length) }
            if let language = detail.language { Text(language) }
            if detail.availability == .available {
                Label("In Jellyfin", systemImage: "checkmark.circle.fill").foregroundStyle(BurrowColor.success)
            } else {
                Text(detail.availability.label)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.toggleList(detail.ref) }
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
            if detail.availability == .available {
                Button("Afspelen", systemImage: "play") {}
                    .disabled(true)
                    .help("Afspelen in Jellyfin komt in een volgende stap")
            }
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

    private var similar: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(model.similar) { title in
                Button {
                    model.open(title.ref, focusInside: true)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Artwork(title: title, style: .poster)
                            .aspectRatio(2 / 3, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Text(title.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var makers: some View {
        let leads = detail.credits.filter { $0.role != "cast" }
        let cast = detail.credits.filter { $0.role == "cast" }
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            if !leads.isEmpty {
                GridRow {
                    Text(detail.mediaType == .tv ? "Maker" : "Regie").foregroundStyle(.secondary)
                    names(leads)
                }
            }
            if !cast.isEmpty {
                GridRow {
                    Text("Met").foregroundStyle(.secondary)
                    names(cast)
                }
            }
        }
        .font(.system(size: 12))
    }

    private func names(_ credits: [Credit]) -> some View {
        FlowLayout(spacing: 4) {
            ForEach(credits, id: \.id) { credit in
                Button(credit.name) { model.query = credit.name }
                    .buttonStyle(.link)
                    .foregroundStyle(.primary)
                    .help("Zoek alles met \(credit.name)")
            }
        }
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
        .padding(.top, 20)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(BurrowColor.linen.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Korte fragmenten in de taal van de bron. De volledige review kan spoilers bevatten.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Wraps its children like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(bounds.width, subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return (CGSize(width: widest, height: y + line), points)
    }
}
