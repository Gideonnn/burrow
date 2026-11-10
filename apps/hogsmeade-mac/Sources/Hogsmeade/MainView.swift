import BurrowUI
import HogsmeadeCore
import HogsmeadeUI
import SwiftUI

/// The window (docs/design/outings-app-native.html): a sidebar that narrows,
/// the poster wall with tonight on top, and an outing's page on top of the
/// wall in a navigation stack, so the system draws back and forward.
struct MainView: View {
    @Environment(OutingsModel.self) private var model
    @State private var adding = false
    @FocusState private var searchFocused: Bool
    @SceneStorage("hogsmeade.sidebar") private var storedPlace = OutingsModel.Place.upcoming.rawValue

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            NavigationStack(path: Binding(
                get: { model.openId.map { [$0] } ?? [] },
                set: { path in if let id = path.last { model.open(id) } else { model.close() } }
            )) {
                WallView()
                    .navigationTitle(model.page == .upcoming ? "Binnenkort" : "Geweest")
                    .navigationSubtitle(model.summaryLine)
                    .navigationDestination(for: String.self) { id in
                        if let outing = model.outings.first(where: { $0.id == id }) {
                            OutingPage(outing: outing)
                                .navigationTitle(outing.title)
                        }
                    }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let outing = model.open {
                    ShareLink(item: shareText(outing)) { Label("Deel", systemImage: "square.and.arrow.up") }
                        .help("Deel de datum en de plek")
                }
                Button { adding = true } label: { Label("Nieuw", systemImage: "plus") }
                    .help("Nieuw uitje (⌘N)")
                    .disabled(!model.canOrganize)
            }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Zoek een uitje")
        .modifier(SearchFocus(focused: $searchFocused))
        .sheet(isPresented: $adding) { NewOutingSheet() }
        .onChange(of: model.newRequest) { adding = true }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .onChange(of: model.query) { if !model.query.isEmpty, model.open != nil { model.close() } }
        .onKeyPress(.escape) {
            guard model.open != nil || !model.query.isEmpty else { return .ignored }
            model.escape()
            return .handled
        }
        .onAppear { if let place = OutingsModel.Place(rawValue: storedPlace) { model.place = place } }
        .onChange(of: model.place) { storedPlace = model.place.rawValue }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast.message)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .modifier(Glass(shape: Capsule()))
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
        .overlay { ConfettiBurst(trigger: model.lastChange?.kind == .allDone ? model.lastChange?.id : nil) }
    }

    private func shareText(_ outing: Outing) -> String {
        [outing.title, OutingFormat.when(outing), OutingFormat.whereLines(outing).joined(separator: ", "), outing.url]
            .compactMap { $0 }.joined(separator: "\n")
    }
}

/// ⌘F focuses the toolbar's search field; `searchFocused` came with macOS 15.
private struct SearchFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.searchFocused(focused)
        } else {
            content
        }
    }
}

/// Binnenkort and Geweest, then who goes and what kind, each a filter.
struct Sidebar: View {
    @Environment(OutingsModel.self) private var model

    var body: some View {
        // A click beside a row never leaves the list without a place.
        List(selection: Binding(get: { model.place }, set: { if let place = $0 { model.place = place } })) {
            Section {
                CountedLabel(title: "Binnenkort", icon: "sparkles", count: model.upcoming.count)
                    .tag(OutingsModel.Place.upcoming)
                CountedLabel(title: "Geweest", icon: "calendar", count: model.past.count)
                    .tag(OutingsModel.Place.past)
            } header: {
                SidebarSectionHeader("Uitjes")
            }
            if !model.people.isEmpty {
                Section {
                    ForEach(model.people) { person in
                        HStack(spacing: 6) {
                            Label { Text(person.name).lineLimit(1) } icon: { Avatar(person.name, size: 18) }
                            Spacer(minLength: 0)
                            SidebarCount(count: model.count(for: person))
                        }
                        .tag(OutingsModel.Place.person(person.id))
                    }
                } header: {
                    SidebarSectionHeader("Wie gaat")
                }
            }
            if !model.kinds.isEmpty {
                Section {
                    ForEach(model.kinds, id: \.key) { kind in
                        CountedLabel(title: kind.label, icon: Outing.symbol(forKind: kind.key), count: kind.count)
                            .tag(OutingsModel.Place.kind(kind.key))
                    }
                } header: {
                    SidebarSectionHeader("Soort")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                UpdateBanner(appName: "Hogsmeade") { (NSApp.delegate as? AppDelegate)?.restart() }
                ConnectionBadge(
                    host: model.connection?.serverURL.host() ?? "", detail: "Ingelogd als \(model.myName)",
                    reachable: model.reachability.isReachable, busy: model.isLoading, appName: "Hogsmeade")
            }
        }
    }
}

extension Outing {
    /// The symbol for a kind: music for concerts, a tent for festivals, masks for theatre.
    public static func symbol(forKind kind: String?) -> String {
        let k = (kind ?? "").lowercased()
        if k.contains("festival") || k.contains("camp") { return "tent" }
        if k.contains("concert") || k.contains("muziek") || k.contains("optreden") || k.contains("band") { return "music.note" }
        if k.contains("theater") || k.contains("toneel") || k.contains("cabaret") || k.contains("musical") || k.contains("show") { return "theatermasks" }
        if k.contains("feest") || k.contains("party") || k.contains("borrel") { return "party.popper" }
        if k.contains("film") || k.contains("bios") { return "film" }
        if k.contains("sport") || k.contains("wedstrijd") { return "sportscourt" }
        return "ticket"
    }
}
