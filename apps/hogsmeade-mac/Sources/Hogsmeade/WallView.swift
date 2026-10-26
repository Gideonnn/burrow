import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

/// The window: a night with the posters as a hand of cards, the pages as a
/// floating island at the bottom, and the scrapbook over everything when a
/// title is open. The model is Lumos's; only the face differs.
struct WallView: View {
    @Environment(LumosModel.self) private var model
    @FocusState private var focused: LumosModel.Focus?
    @State private var celebration: UUID?

    var body: some View {
        ZStack {
            Palette.night.ignoresSafeArea()
            Orbs()
            VStack(spacing: 0) {
                TopBar(focused: $focused)
                ContentPage(focused: $focused)
            }
            .opacity(model.inspectorShown ? 0 : 1)
            if model.inspectorShown {
                Scrapbook(focused: $focused)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            VStack(spacing: 10) {
                Spacer()
                ToastPill()
                if !model.inspectorShown { Island() }
            }
            .padding(.bottom, 18)
            ConfettiBurst(trigger: celebration)
        }
        .ignoresSafeArea(edges: .top)
        .animation(.easeOut(duration: 0.22), value: model.inspectorShown)
        .onChange(of: model.lastChange) {
            // A title that lands on the household's list is the moment the evening is settled.
            if let change = model.lastChange, change.kind == .listed, change.scope == .shared { celebration = change.id }
        }
        .onChange(of: model.focus) { if model.focus != .search { focused = model.focus } }
        .onChange(of: focused) { if let focused, focused != model.focus { model.focus = focused } }
        .onChange(of: model.loaded, initial: true) { ImageLoader.shared.prefetch(rows: model.loaded) }
        .onAppear { focused = .content }
    }
}

// MARK: The top bar

struct TopBar: View {
    @Environment(LumosModel.self) private var model
    var focused: FocusState<LumosModel.Focus?>.Binding
    @FocusState private var searching: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            // Room for the traffic lights of the title bar that is not drawn.
            Spacer().frame(width: 72)
            HStack(spacing: 8) {
                Image(systemName: "signpost.right.fill").foregroundStyle(Palette.lemon)
                Text("Hogsmeade").font(.round(15, .heavy))
                if model.isFixture {
                    Text("Testgegevens").pill(Palette.peach.opacity(0.25), Palette.peach, height: 22).font(.round(10, .bold))
                        .help("De catalogus is testdata van de server, niet Seerr of TMDB.")
                        .accessibilityIdentifier("lumos.fixture")
                }
                if !model.reachability.isReachable {
                    Text("Server even weg").pill(Palette.hot.opacity(0.3), Palette.candy, height: 22).font(.round(10, .bold))
                        .help("Hogsmeade probeert het vanzelf opnieuw.")
                }
                if model.isLoading { ProgressView().controlSize(.mini) }
            }
            .foregroundStyle(.white)
            Spacer()
            UpdateBanner(appName: "Hogsmeade") { (NSApp.delegate as? AppDelegate)?.restart() }
                .frame(maxWidth: 240)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.mutedOnNight)
                TextField("Zoek een film of serie", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.round(13, .semibold))
                    .foregroundStyle(.white)
                    .frame(width: searching || !model.query.isEmpty ? 220 : 140)
                    .focused($searching)
                    .onSubmit { model.enterResults(); focused.wrappedValue = .content }
                    .onExitCommand { model.query = ""; focused.wrappedValue = .content }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.mutedOnNight) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(.white.opacity(searching ? 0.16 : 0.1)))
            .animation(.easeOut(duration: 0.2), value: searching)
            .onChange(of: model.searchFocusRequest) { searching = true }
            .onChange(of: searching) { if searching { model.focus = .search } }
            ScopeToggle()
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(height: 64)
    }
}

/// Samen, or your own name: who the wall is for.
struct ScopeToggle: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        HStack(spacing: 3) {
            option("Samen", scope: .shared) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Palette.violet))
            }
            option(model.myName, scope: .mine) { PersonBadge(model.myName, size: 20) }
        }
        .padding(3)
        .background(Capsule().fill(.white.opacity(0.1)))
        .help("Samen kiest uit onze lijst; je eigen lijst ziet alleen jij.")
    }

    private func option(_ label: String, scope: ListScope, @ViewBuilder badge: () -> some View) -> some View {
        let on = model.scope == scope
        return Button {
            model.scope = scope
        } label: {
            HStack(spacing: 7) {
                badge()
                Text(label)
            }
            .font(.round(13, .bold))
            .foregroundStyle(on ? Palette.onLemon : .white)
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 30)
            .background(Capsule().fill(on ? Palette.lemon : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: The pages

struct ContentPage: View {
    @Environment(LumosModel.self) private var model
    var focused: FocusState<LumosModel.Focus?>.Binding

    var body: some View {
        Group {
            if model.status != nil, model.status?.dataOrigin == nil, ![.passed, .taste].contains(model.page) {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 44, weight: .light)).foregroundStyle(Palette.mutedOnNight)
                    Text("Nog geen catalogus").font(.round(28, .black))
                    Text("De server is nog niet aan Seerr gekoppeld. Lijsten blijven bewaard.").foregroundStyle(Palette.mutedOnNight)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch model.page {
                case .passed, .taste: VerdictWall(focused: focused)
                default: CardWall(focused: focused)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Rows of posters, driven by the keyboard through the model exactly like Lumos.
struct CardWall: View {
    @Environment(LumosModel.self) private var model
    var focused: FocusState<LumosModel.Focus?>.Binding

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if model.page == .discover { Hello() }
                    if model.page == .search, !model.searchCredits.isEmpty { CreditsRow() }
                    ForEach(model.rows) { row in
                        if row.key == "tonight" {
                            FanRow(row: row)
                        } else if row.grid {
                            PosterGrid(row: row)
                        } else {
                            Shelf(row: row)
                        }
                    }
                    Spacer().frame(height: 70)
                }
                .padding(.top, 8)
            }
            .focusable()
            .focused(focused, equals: .content)
            .focusEffectDisabled()
            .onExitCommand { model.escape() }
            .onKeyPress(phases: .down) { press in handle(press) }
            .onChange(of: model.cursor) {
                guard let cursor = model.cursor else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(cursor.description) }
            }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) || press.modifiers.contains(.option) {
            return .ignored
        }
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
        case .leftArrow: model.move(.left)
        case .rightArrow: model.move(.right)
        case .upArrow: model.move(.up)
        case .downArrow: model.move(.down)
        case .home: model.move(.home)
        case .end: model.move(.end)
        case .space: model.toggleInspector()
        case .return:
            guard let cursor = model.cursor else { return .ignored }
            model.open(cursor.ref, from: cursor, focusInside: true)
        case .escape: model.escape()
        default:
            switch press.characters.lowercased() {
            case "j": Task { await model.toggleList() }
            case "n": model.reasonMenu = model.cursor?.ref
            case "t": Task { await model.playTrailer() }
            case "k": Task { await model.watch() }
            case "z": Task { await model.undo() }
            case "/": model.requestSearchFocus()
            default: return .ignored
            }
        }
        return .handled
    }
}

/// The greeting on Ontdekken: who it is for, what stands on top, and tonight's mood.
struct Hello: View {
    @Environment(LumosModel.self) private var model

    private var top: TitleSummary? { model.rows.first(where: { $0.key == "tonight" })?.items.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.scope == .shared ? "Samen" : "Voor \(model.myName)")
                .font(.round(14, .bold))
                .kerning(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.lemon)
            Text(model.scope == .shared ? "Wat kijken we vanavond?" : "Wat kijk jij vanavond?")
                .font(.round(64, .black))
                .kerning(-1.5)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let top {
                HStack(spacing: 0) {
                    Text("Bovenaan: ")
                    Text(top.title).foregroundStyle(.white)
                    if let why = top.match { Text(" · \(why)") } else if !top.line.isEmpty { Text(" · \(top.line)") }
                }
                .font(.round(18, .medium))
                .foregroundStyle(Palette.mutedOnNight)
                .lineLimit(1)
            }
            HStack(spacing: 8) {
                Text("Vanavond").font(.round(13, .bold)).foregroundStyle(Palette.dimOnNight)
                ForEach(LumosModel.Mood.allCases, id: \.self) { mood in
                    let on = model.mood == mood
                    Button { model.mood = mood } label: {
                        Text(mood.rawValue).pill(on ? Palette.lemon : .white.opacity(0.1), on ? Palette.onLemon : .white, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                if model.listCount > 0 {
                    Button {
                        Task { await model.show(.list) }
                    } label: {
                        Label("\(model.listCount) op \(model.scope == .shared ? "onze" : "jouw") lijst", systemImage: "bookmark.fill")
                            .pill(Palette.mint.opacity(0.9), Palette.onMint, height: 30)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 64)
        .padding(.top, 10)
    }
}

struct CreditsRow: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Text("Makers en cast").font(.round(13, .bold)).foregroundStyle(Palette.dimOnNight)
            ForEach(model.searchCredits, id: \.id) { credit in
                Button { model.query = credit.name } label: {
                    Text(credit.name).pill(.white.opacity(0.1), .white, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 64)
    }
}

struct RowHeader: View {
    let row: TitleRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // A grid is a page of its own, so its title is the page's.
            Text(row.title).font(.round(row.grid ? 40 : 22, .heavy)).kerning(row.grid ? -0.8 : 0).foregroundStyle(.white)
            if let subtitle = row.subtitle {
                Text(subtitle).font(.round(13, .medium)).foregroundStyle(Palette.dimOnNight).lineLimit(1)
            }
        }
        .padding(.horizontal, 64)
    }
}

struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.round(14, .semibold))
            .foregroundStyle(Palette.mutedOnNight)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6])).foregroundStyle(.white.opacity(0.25)))
            .padding(.horizontal, 64)
    }
}

/// Tonight's proposals as a hand of cards: fanned, overlapping, each a
/// little turned. Hover or the cursor lifts one out of the hand.
struct FanRow: View {
    @Environment(LumosModel.self) private var model
    let row: TitleRow

    private let cardWidth: CGFloat = 176
    private var cardHeight: CGFloat { (cardWidth * 1.45).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeader(row: row)
            if row.items.isEmpty, let empty = row.empty {
                EmptyNote(text: empty)
            } else {
                // The hand overlaps a little and scrolls when it is wider than the window.
                ScrollView(.horizontal, showsIndicators: false) {
                    let mid = Double(row.items.count - 1) / 2
                    HStack(alignment: .top, spacing: -22) {
                        ForEach(Array(row.items.enumerated()), id: \.element.id) { index, title in
                            let distance = Double(index) - mid
                            PosterCard(
                                title: title, card: CardID(row: row.key, ref: title.ref), width: cardWidth,
                                angle: max(-12, min(12, distance * 2.6)))
                            .padding(.top, 26 + CGFloat(abs(distance)) * 6)
                        }
                    }
                    .padding(.horizontal, 64)
                    .padding(.bottom, 34)
                    .frame(minWidth: 1000, alignment: .center)
                }
                .frame(height: cardHeight + 60 + 30)
                .padding(.vertical, -14)
            }
        }
    }
}

/// One horizontal shelf of posters.
struct Shelf: View {
    let row: TitleRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeader(row: row)
            if row.items.isEmpty, let empty = row.empty {
                EmptyNote(text: empty)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(Array(row.items.enumerated()), id: \.element.id) { index, title in
                            PosterCard(title: title, card: CardID(row: row.key, ref: title.ref), angle: index.isMultiple(of: 2) ? -1.6 : 1.6)
                        }
                    }
                    .padding(.horizontal, 64)
                    .padding(.vertical, 22)
                }
                .padding(.vertical, -14)
            }
        }
    }
}

/// A page of posters in lines; the model learns how many fit in a line.
struct PosterGrid: View {
    @Environment(LumosModel.self) private var model
    let row: TitleRow
    @State private var columns = 6

    private let cardWidth: CGFloat = 132
    private let gap: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RowHeader(row: row)
            if row.items.isEmpty, let empty = row.empty {
                EmptyNote(text: empty)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: gap, alignment: .top), count: columns),
                    alignment: .leading, spacing: 30
                ) {
                    ForEach(Array(row.items.enumerated()), id: \.element.id) { index, title in
                        PosterCard(title: title, card: CardID(row: row.key, ref: title.ref), width: cardWidth, angle: index.isMultiple(of: 2) ? -1.4 : 1.4)
                    }
                }
                .padding(.horizontal, 64)
                .padding(.top, 10)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { fit(geometry.size.width) }
                    .onChange(of: geometry.size.width) { fit(geometry.size.width) }
            }
        }
    }

    private func fit(_ width: CGFloat) {
        let next = max(1, Int((width - 128 + gap) / (cardWidth + gap)))
        columns = next
        model.setColumns(next, for: row.key)
    }
}

// MARK: Verdict pages

/// Overgeslagen and Smaak: what the scope decided, each with its way back.
struct VerdictWall: View {
    @Environment(LumosModel.self) private var model
    var focused: FocusState<LumosModel.Focus?>.Binding

    private var passed: Bool { model.page == .passed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(passed ? "Overgeslagen" : "Smaak").font(.round(48, .black)).foregroundStyle(.white)
                    Text(passed
                        ? "Niet nu is geen afkeer, en ‘Al gezien’ verlaagt de smaak niet. Terugzetten kan altijd."
                        : "Alles begint neutraal. Bijstellingen gelden alleen voor voorstellen, nooit voor zoeken.")
                        .font(.round(15, .medium)).foregroundStyle(Palette.mutedOnNight)
                }
                if model.verdictItems.isEmpty {
                    EmptyNote(text: passed ? "Niets overgeslagen. Gebruik N of het kruisje op een poster." : "Nog geen bijstellingen. Kies in het plakboek Meer of Minder zoals dit.")
                        .padding(.horizontal, -64)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(model.verdictItems) { verdict in
                            HStack(spacing: 14) {
                                Artwork(title: verdict.title, style: .poster, maxPixels: 120)
                                    .frame(width: 40, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Button(verdict.title.title) { model.open(verdict.title.ref, focusInside: true) }
                                        .buttonStyle(.plain)
                                        .font(.round(16, .heavy))
                                        .foregroundStyle(.white)
                                    Text("\(label(verdict)) · door \(verdict.by.name)").font(.round(12, .medium)).foregroundStyle(Palette.mutedOnNight)
                                }
                                Spacer()
                                Button {
                                    Task { await model.restore(verdict) }
                                } label: {
                                    Text(passed ? "Terugzetten" : "Weghalen").pill(Palette.lemon, Palette.onLemon, height: 30)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06)))
                        }
                    }
                }
                Spacer().frame(height: 70)
            }
            .padding(.horizontal, 64)
            .padding(.top, 10)
        }
        .focusable()
        .focused(focused, equals: .content)
        .focusEffectDisabled()
        .onExitCommand { model.escape() }
        .onKeyPress(phases: .down) { press in
            if press.characters.lowercased() == "z" { Task { await model.undo() }; return .handled }
            if press.characters == "/" { model.requestSearchFocus(); return .handled }
            return .ignored
        }
    }

    private func label(_ verdict: Verdict) -> String {
        switch verdict.kind {
        case .seen: "Al gezien"
        case .notNow: verdict.reason ?? "Niet nu"
        case .moreLikeThis: "Meer zoals dit"
        case .lessLikeThis: "Minder zoals dit"
        }
    }
}

// MARK: Island and toast

/// The floating navigation at the bottom, the pages as pills.
struct Island: View {
    @Environment(LumosModel.self) private var model

    private var items: [(String, String, LumosModel.Page, Int?)] {
        [
            ("Vanavond", "sparkles", .discover, nil),
            (model.scope == .shared ? "Onze lijst" : "Jouw lijst", "bookmark.fill", .list, model.listCount),
            ("Films", "film", .movies, nil),
            ("Series", "tv", .series, nil),
            ("Jellyfin", "checkmark.circle", .available, nil),
            ("Smaak", "slider.horizontal.3", .taste, nil),
            ("Overgeslagen", "eye.slash", .passed, model.passedCount),
        ]
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.2) { label, symbol, page, count in
                let on = model.page == page || (model.page == .search && page == .discover)
                Button {
                    Task { await model.show(page) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                        Text(label)
                        if let count, count > 0 {
                            Text(String(count))
                                .font(.round(10, .heavy))
                                .padding(.horizontal, 6)
                                .frame(height: 16)
                                .background(Capsule().fill(on ? Palette.onLemon.opacity(0.15) : Palette.hot))
                        }
                    }
                    .font(.round(13, .bold))
                    .foregroundStyle(on ? Palette.onLemon : Palette.mutedOnNight)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(Capsule().fill(on ? Palette.lemon : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(help(page))
            }
        }
        .padding(5)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 12))
    }

    private func help(_ page: LumosModel.Page) -> String {
        switch page {
        case .discover: "Voorstellen voor vanavond (⌘1)"
        case .list: "Wat jullie bewaard hebben (⌘2)"
        case .taste: "Meer en minder zoals dit (⌘3)"
        case .available: "Staat al op de server"
        default: ""
        }
    }
}

struct ToastPill: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 12) {
                Text(toast.message).font(.round(13, .bold)).lineLimit(2)
                if toast.canUndo {
                    Button {
                        Task { await model.undo() }
                    } label: {
                        Label("Ongedaan maken", systemImage: "arrow.uturn.backward")
                            .pill(.white.opacity(0.14), .white, height: 26)
                            .font(.round(12, .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Z of ⌘Z")
                }
            }
            .foregroundStyle(.white)
            .padding(.leading, 16)
            .padding(.trailing, toast.canUndo ? 6 : 16)
            .padding(.vertical, 7)
            .background(Capsule().fill(Palette.nightDeep.opacity(0.92)).shadow(color: .black.opacity(0.4), radius: 14, y: 8))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}
