import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

/// The sidebar and the rows; a title or a person opens as a page over the
/// rows in the same column, so going in and out is one key and no wait.
struct MainView: View {
    @Environment(LumosModel.self) private var model
    @FocusState private var focused: LumosModel.Focus?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 212, max: 260)
        } detail: {
            ZStack {
                ContentArea(focused: $focused)
                    .opacity(model.stack.isEmpty ? 1 : 0)
                    .allowsHitTesting(model.stack.isEmpty)
                    .accessibilityHidden(!model.stack.isEmpty)
                if let place = model.stack.last {
                    PageView(place: place, focused: $focused)
                        .id(place)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: model.stack)
            .navigationTitle(pageTitle)
            .navigationSubtitle(model.stack.isEmpty ? model.subtitle : "")
            .toolbar { MainToolbar() }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Titel, maker, cast of kenmerk")
        .modifier(SearchFocus(request: model.searchFocusRequest))
        .onSubmit(of: .search) {
            model.enterResults()
            focused = .content
        }
        .onChange(of: model.focus) { if model.focus != .search { focused = model.focus } }
        .onChange(of: focused) { if let focused, focused != model.focus { model.focus = focused } }
        .overlay(alignment: .bottom) { ToastView() }
        .onAppear {
            focused = .content
            ImageLoaderHook.prefetch = { urls in
                ImageLoader.shared.prefetch(urls.compactMap(URL.init(string:)), maxPixels: Artwork.posterPixels)
            }
        }
        .onChange(of: model.loaded, initial: true) { ImageLoader.shared.prefetch(rows: model.loaded) }
    }

    private var pageTitle: String {
        switch model.stack.last {
        case .title: model.detail?.title ?? model.inspected.flatMap { model.summary($0)?.title } ?? model.title
        case .person: model.personPage?.name ?? "Persoon"
        case nil: model.title
        }
    }
}

/// ⌘F and / put the cursor in the search field (macOS 15 and later).
private struct SearchFocus: ViewModifier {
    let request: Int
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .searchFocused($focused)
                .onChange(of: request) { focused = true }
        } else {
            content
        }
    }
}

/// A title's page or a person's, over the rows.
struct PageView: View {
    @Environment(LumosModel.self) private var model
    let place: LumosModel.Place
    var focused: FocusState<LumosModel.Focus?>.Binding

    var body: some View {
        Group {
            switch place {
            case .title(let ref): TitlePage(ref: ref, focused: focused)
            case .person(let id): PersonPage(id: id, focused: focused)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BurrowColor.plaster.opacity(0.35))
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { model.page == .search ? nil : model.page }, set: { page in
            if let page { Task { await model.show(page) } }
        })) {
            Section {
                Label("Ontdekken", systemImage: "sparkles").tag(LumosModel.Page.discover)
                Label("Zoeker", systemImage: "binoculars").tag(LumosModel.Page.explore)
                CountedLabel(title: model.scope == .shared ? "Onze lijst" : "Jouw lijst", icon: "bookmark", count: model.listCount)
                    .tag(LumosModel.Page.list)
            } header: {
                SidebarSectionHeader("Kijken")
            }
            Section {
                Label("Films", systemImage: "film").tag(LumosModel.Page.movies)
                Label("Series", systemImage: "tv").tag(LumosModel.Page.series)
                Label("Klaar in Jellyfin", systemImage: "checkmark.circle").tag(LumosModel.Page.available)
            } header: {
                SidebarSectionHeader("Bibliotheek")
            }
            Section {
                Label("Smaak", systemImage: "slider.horizontal.3").tag(LumosModel.Page.taste)
                CountedLabel(title: "Overgeslagen", icon: "eye.slash", count: model.passedCount).tag(LumosModel.Page.passed)
            } header: {
                SidebarSectionHeader("Bijstellen")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if model.isFixture { FixtureNote() }
                UpdateBanner(appName: "Lumos") { (NSApp.delegate as? AppDelegate)?.restart() }
                ConnectionBadge(
                    host: model.connection?.serverURL.host() ?? "",
                    detail: model.status?.dataOrigin == nil ? "Catalogus niet gekoppeld" : "Ingelogd als \(model.myName)",
                    reachable: model.reachability.isReachable, busy: model.isLoading, appName: "Lumos")
            }
        }
    }
}

/// Shown for as long as the catalogue is the fixtures, so test titles are
/// never taken for the real ones.
struct FixtureNote: View {
    var body: some View {
        HStack(spacing: 8) {
            FixtureBadge()
            Text("Verzonnen titels; niets wordt aangevraagd")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FixtureBadge: View {
    var body: some View {
        Text("Testgegevens")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(BurrowColor.warning)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(BurrowColor.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .help("De catalogus is testdata van de server, niet Seerr of TMDB.")
            .accessibilityIdentifier("lumos.fixture")
    }
}

// MARK: Toolbar

struct MainToolbar: ToolbarContent {
    @Environment(LumosModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .navigation) {
            if model.inspectorShown {
                Button { model.back() } label: { Label("Terug", systemImage: "chevron.left") }
                    .help("Terug (Esc of ⌘[)")
            }
            if model.isFixture { FixtureBadge() }
        }
        ToolbarItem {
            Picker("Voor wie", selection: $model.scope) {
                Text("Samen").tag(ListScope.shared)
                Text(model.myName).tag(ListScope.mine)
            }
            .pickerStyle(.segmented)
            .help("Samen kiest uit onze lijst; je eigen lijst ziet alleen jij.")
        }
    }
}

// MARK: Content

struct ContentArea: View {
    @Environment(LumosModel.self) private var model
    var focused: FocusState<LumosModel.Focus?>.Binding

    var body: some View {
        Group {
            if model.status != nil, model.status?.dataOrigin == nil, ![.passed, .taste].contains(model.page) {
                ContentUnavailableView(
                    "Lumos is niet gekoppeld", systemImage: "film.stack",
                    description: Text("De server heeft nog geen catalogus. Lijsten blijven bewaard."))
            } else {
                switch model.page {
                case .passed: PassedPage()
                case .taste: TastePage()
                default: CardPage(focused: focused)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BurrowColor.plaster.opacity(0.35))
    }
}

/// Rows or grids of cards, driven by the keyboard through the model.
struct CardPage: View {
    @Environment(LumosModel.self) private var model
    var focused: FocusState<LumosModel.Focus?>.Binding

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    switch model.page {
                    case .discover: MoodBar()
                    case .explore: ExploreBar()
                    case .movies, .series: BrowseBar()
                    case .search where !model.searchCredits.isEmpty: CreditsBar()
                    default: EmptyView()
                    }
                    ForEach(model.rows) { row in
                        if row.grid { GridSection(row: row) } else { Shelf(row: row) }
                    }
                    if model.loadingMore {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 16)
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

struct MoodBar: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Text("Vanavond").font(.callout).foregroundStyle(.secondary)
            ForEach(LumosModel.Mood.allCases, id: \.self) { mood in
                Button(mood.rawValue) { model.mood = mood }
                    .buttonStyle(ChipStyle(on: model.mood == mood))
            }
        }
        .padding(.horizontal, 24)
    }
}

/// The Zoeker's one button: new surprise rows.
struct ExploreBar: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await model.shuffle() } } label: { Label("Verras me", systemImage: "dice") }
                .help("Nieuwe verrassingen: een ander decennium en een andere greep")
            Text("Rijen uit jullie smaak en lijst, wat nu veel bekeken wordt, het beste van dit jaar, Nederlandse films en verborgen parels.")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 24)
    }
}

/// Films and Series: how the shelf is sorted, and narrowed by genre, Dutch
/// or a decade.
struct BrowseBar: View {
    @Environment(LumosModel.self) private var model

    private var type: MediaType { model.page == .series ? .tv : .movie }
    private var state: LumosModel.Browse { model.browse[type] ?? LumosModel.Browse() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(BrowseSort.allCases, id: \.self) { sort in
                    Button(sort.label) { Task { await model.setBrowse { $0.sort = sort } } }
                        .buttonStyle(ChipStyle(on: state.sort == sort))
                }
            }
            HStack(spacing: 6) {
                Menu {
                    Button("Alle genres") { Task { await model.setBrowse { $0.genre = nil } } }
                    Divider()
                    ForEach(state.genres) { genre in
                        Button(genre.name) { Task { await model.setBrowse { $0.genre = genre } } }
                    }
                } label: {
                    Label(state.genre?.name ?? "Genre", systemImage: "chevron.down")
                }
                .menuStyle(.button)
                .buttonStyle(ChipStyle(on: state.genre != nil))
                .fixedSize()
                .disabled(state.genres.isEmpty)
                Menu {
                    Button("Alle jaren") { Task { await model.setBrowse { $0.decade = nil } } }
                    Divider()
                    ForEach(Array(stride(from: 2020, through: 1950, by: -10)), id: \.self) { decade in
                        Button("Jaren \(String(decade).suffix(2))") { Task { await model.setBrowse { $0.decade = decade } } }
                    }
                } label: {
                    Label(state.decade.map { "Jaren \(String($0).suffix(2))" } ?? "Decennium", systemImage: "chevron.down")
                }
                .menuStyle(.button)
                .buttonStyle(ChipStyle(on: state.decade != nil))
                .fixedSize()
                Button("Nederlands") { Task { await model.setBrowse { $0.dutch.toggle() } } }
                    .buttonStyle(ChipStyle(on: state.dutch))
                    .help("Alleen Nederlandstalige producties")
                if state.totalPages > 1 {
                    Text("pagina \(state.page) van \(state.totalPages)").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 24)
    }
}

struct CreditsBar: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Text("Makers en cast").font(.callout).foregroundStyle(.secondary)
            ForEach(model.searchCredits, id: \.id) { credit in
                Button(credit.name) { model.openPerson(credit.id, name: credit.name) }
                    .buttonStyle(ChipStyle(on: false))
                    .help("Open \(credit.name)")
            }
        }
        .padding(.horizontal, 24)
    }
}

struct ChipStyle: ButtonStyle {
    var on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? AnyShapeStyle(BurrowColor.lumos) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule().fill(on ? BurrowColor.lumos.opacity(0.14) : Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(on ? .clear : BurrowColor.hairline))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

struct RowHeader: View {
    let row: TitleRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.title).font(.system(size: 15, weight: .semibold))
            if let subtitle = row.subtitle {
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 24)
    }
}

struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(BurrowColor.hairline))
            .padding(.horizontal, 24)
    }
}

/// One horizontal row of stills or posters.
struct Shelf: View {
    let row: TitleRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !row.title.isEmpty { RowHeader(row: row) }
            if row.items.isEmpty, let empty = row.empty {
                EmptyRow(text: empty)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(row.items) { title in
                            CardView(title: title, card: CardID(row: row.key, ref: title.ref), style: row.style)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

/// A page of posters in lines; the model learns how many fit in a line,
/// and the shelf's last lines ask for the next page.
struct GridSection: View {
    @Environment(LumosModel.self) private var model
    let row: TitleRow
    @State private var columns = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowHeader(row: row)
            if row.items.isEmpty, let empty = row.empty {
                EmptyRow(text: empty)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(row.style.cardWidth), spacing: 14, alignment: .top), count: columns),
                    alignment: .leading, spacing: 18
                ) {
                    ForEach(Array(row.items.enumerated()), id: \.element.id) { index, title in
                        CardView(title: title, card: CardID(row: row.key, ref: title.ref), style: row.style)
                            .onAppear {
                                if row.key.hasPrefix("browse-"), index >= row.items.count - columns * 2 { Task { await model.loadMore() } }
                            }
                    }
                }
                .padding(.horizontal, 24)
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
        let next = max(1, Int((width - 48 + 14) / row.style.cardStep))
        columns = next
        model.setColumns(next, for: row.key)
    }
}

// MARK: Toast

struct ToastView: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 12) {
                Text(toast.message).font(.callout).lineLimit(2)
                if toast.canUndo {
                    Button {
                        Task { await model.undo() }
                    } label: {
                        Label("Ongedaan maken", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Z of ⌘Z")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}
