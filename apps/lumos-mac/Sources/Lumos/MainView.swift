import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

/// Two columns and an inspector: the sidebar, the image rows, and the
/// details on the right. Only the rows and the inspector scroll.
struct MainView: View {
    @Environment(LumosModel.self) private var model
    @FocusState private var focused: LumosModel.Focus?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 212, max: 260)
        } detail: {
            ContentArea(focused: $focused)
                .navigationTitle(model.title)
                .navigationSubtitle(model.subtitle)
                .toolbar { MainToolbar() }
                .inspector(isPresented: Binding(get: { model.inspectorShown }, set: { if !$0 { model.closeInspector() } })) {
                    InspectorView(focused: $focused)
                        .inspectorColumnWidth(min: 340, ideal: 404, max: 480)
                }
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
        .onAppear { focused = .content }
        .onChange(of: model.loaded, initial: true) { ImageLoader.shared.prefetch(rows: model.loaded) }
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

// MARK: Sidebar

struct Sidebar: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { model.page == .search ? nil : model.page }, set: { page in
            if let page { Task { await model.show(page) } }
        })) {
            Section {
                Label("Ontdekken", systemImage: "sparkles").tag(LumosModel.Page.discover)
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
        if model.isFixture {
            ToolbarItem(placement: .navigation) { FixtureBadge() }
        }
        ToolbarItem {
            Picker("Voor wie", selection: $model.scope) {
                Text("Samen").tag(ListScope.shared)
                Text(model.myName).tag(ListScope.mine)
            }
            .pickerStyle(.segmented)
            .help("Samen kiest uit onze lijst; je eigen lijst ziet alleen jij.")
        }
        ToolbarItem {
            Button {
                model.toggleInspector()
            } label: {
                Label("Details", systemImage: "sidebar.trailing")
            }
            .help("Details tonen of verbergen (spatie)")
            .disabled(model.cursor == nil && !model.inspectorShown)
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
                    if model.page == .discover { MoodBar() }
                    if model.page == .search, !model.searchCredits.isEmpty { CreditsBar() }
                    ForEach(model.rows) { row in
                        if row.grid { GridSection(row: row) } else { Shelf(row: row) }
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

struct CreditsBar: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Text("Makers en cast").font(.callout).foregroundStyle(.secondary)
            ForEach(model.searchCredits, id: \.id) { credit in
                Button(credit.name) { model.query = credit.name }
                    .buttonStyle(ChipStyle(on: false))
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
            RowHeader(row: row)
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

/// A page of posters in lines; the model learns how many fit in a line.
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
                    ForEach(row.items) { title in
                        CardView(title: title, card: CardID(row: row.key, ref: title.ref), style: row.style)
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
