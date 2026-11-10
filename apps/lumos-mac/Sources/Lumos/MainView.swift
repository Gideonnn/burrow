import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

/// The sidebar and the page; a title or a person opens on top in a
/// navigation stack, so the system draws the back button.
struct MainView: View {
    @Environment(LumosModel.self) private var model
    @FocusState private var focused: LumosModel.Focus?
    @FocusState private var searching: Bool
    @SceneStorage("lumos.library.inspector") private var inspectorShown = true
    @SceneStorage("lumos.library.sort") private var librarySort = LibrarySort.newest.rawValue

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            NavigationStack(path: Binding(get: { model.stack }, set: { model.setStack($0) })) {
                PageContent(focused: $focused)
                    .navigationDestination(for: LumosModel.Place.self) { place in
                        PageView(place: place, focused: $focused)
                    }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Voor wie", selection: $model.scope) {
                    Text("Samen").tag(ListScope.shared)
                    Text(model.myName).tag(ListScope.mine)
                }
                .pickerStyle(.segmented)
                .help("Samen kiest uit onze lijst; je eigen lijst ziet alleen jij.")
            }
        }
        .deleteDialog()
        .searchable(text: $model.query, placement: .toolbar, prompt: model.searchPrompt)
        .searchFocused($searching)
        .onChange(of: model.searchFocusRequest) { searching = true }
        .onChange(of: searching) { if searching { model.focus = .search } else if model.focus == .search { model.focus = .content } }
        .onSubmit(of: .search) {
            model.enterResults()
            focused = .content
        }
        .onChange(of: model.focus) { if model.focus != .search { focused = model.focus } }
        .onChange(of: focused) { if let focused, focused != model.focus { model.focus = focused } }
        .onAppear {
            focused = .content
            model.libraryInspector = inspectorShown
            if let sort = LibrarySort(rawValue: librarySort) { model.librarySort = sort }
            ImageLoaderHook.prefetch = { urls in
                ImageLoader.shared.prefetch(urls.compactMap(URL.init(string:)), maxPixels: Artwork.posterPixels)
            }
        }
        .onChange(of: model.libraryInspector) { inspectorShown = model.libraryInspector }
        .onChange(of: model.librarySort) { librarySort = model.librarySort.rawValue }
        .onChange(of: model.loaded, initial: true) { ImageLoader.shared.prefetch(rows: model.loaded) }
    }
}

/// The page the sidebar chose.
struct PageContent: View {
    @Environment(LumosModel.self) private var model
    var focused: FocusState<LumosModel.Focus?>.Binding

    var body: some View {
        Group {
            if model.status != nil, model.status?.dataOrigin == nil, model.page != .library {
                ContentUnavailableView(
                    "Lumos is niet gekoppeld", systemImage: "film.stack",
                    description: Text("De server heeft nog geen catalogus. Lijsten blijven bewaard."))
            } else {
                switch model.page {
                case .discover, .list: CardPage(focused: focused)
                case .library: LibraryPage()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(model.title)
        .navigationSubtitle(model.subtitle)
    }
}

/// A title's page or a person's, on top of the page.
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
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @Environment(LumosModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        List(selection: Binding(get: { model.page }, set: { page in
            if let page { Task { await model.show(page) } }
        })) {
            Label("Ontdekken", systemImage: "sparkles")
                .tag(LumosModel.Page.discover)
            Label(model.listName, systemImage: "bookmark")
                .badge(model.listCount)
                .tag(LumosModel.Page.list)
                .dropDestination(for: String.self) { items, _ in
                    let refs = items.compactMap(TitleRef.init)
                    guard !refs.isEmpty else { return false }
                    Task { for ref in refs { await model.addToList(ref) } }
                    return true
                } isTargeted: { dropTargeted = $0 }
                .help("Sleep een poster of een regel hierheen om hem op de lijst te zetten.")
            Label("Bibliotheek", systemImage: "externaldrive")
                .badge(model.busyCount)
                .tag(LumosModel.Page.library)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if model.isFixture { FixtureNote() }
                UpdateBanner(appName: "Lumos") { (NSApp.delegate as? AppDelegate)?.restart() }
                if let disk = model.disk { DiskMeter(disk: disk) }
            }
            .padding(.bottom, 10)
        }
    }
}

/// The disk on Dobby, always in sight; orange under 15 % free.
struct DiskMeter: View {
    @Environment(LumosModel.self) private var model
    let disk: DiskUse

    var body: some View {
        Button { Task { await model.show(.library) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: disk.used, total: max(disk.total, 1))
                    .tint(disk.tight ? .orange : nil)
                Text("\(Bytes.text(disk.free)) vrij van \(Bytes.text(disk.total))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .accessibilityLabel("Schijf op Dobby: \(Bytes.text(disk.free)) vrij van \(Bytes.text(disk.total))")
        .help("Naar de Bibliotheek")
    }
}

/// Shown for as long as the catalogue is the fixtures, so test titles are
/// never taken for the real ones.
struct FixtureNote: View {
    var body: some View {
        Label("Testgegevens: verzonnen titels, niets wordt aangevraagd", systemImage: "testtube.2")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 16)
            .help("De catalogus is testdata van de server, niet Seerr of TMDB.")
            .accessibilityIdentifier("lumos.fixture")
    }
}

// MARK: The status bar

/// What just happened, with Herstel when it can be taken back.
struct StatusBar: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            line {
                Text(toast.message).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if toast.canUndo, model.canUndo {
                    Button("Herstel") { Task { await model.undo() } }
                        .buttonStyle(.borderless)
                        .help("Z of ⌘Z")
                }
            }
            .id(toast.id)
        } else if !model.reachability.isReachable {
            line {
                Label("Server even niet bereikbaar; Lumos probeert het vanzelf opnieuw.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func line(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
