import BurrowUI
import HogsmeadeCore
import HogsmeadeUI
import SwiftUI

/// The window (docs/design/outings-app-native.html): a sidebar that narrows,
/// the poster wall with tonight on top, and the page of one outing in the
/// same column, with Binnenkort as the way back.
struct MainView: View {
    @Environment(OutingsModel.self) private var model
    @State private var adding = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                if let outing = model.open {
                    OutingPage(outing: outing)
                        .id(outing.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    WallView()
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.25), value: model.open?.id)
            .navigationTitle(model.open?.title ?? (model.page == .upcoming ? "Binnenkort" : "Geweest"))
            .navigationSubtitle(model.open == nil ? model.summaryLine : "")
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if model.open != nil {
                    Button { model.close() } label: { Label("Binnenkort", systemImage: "chevron.left") }
                        .help("Terug naar de wand (Esc)")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                TextField("Zoek een uitje", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .focused($searchFocused)
                    .onExitCommand { searchFocused = false; model.query = "" }
                if let outing = model.open {
                    ShareLink(item: shareText(outing)) { Label("Deel", systemImage: "square.and.arrow.up") }
                        .help("Deel de datum en de plek")
                }
                Button { adding = true } label: { Label("Nieuw", systemImage: "plus") }
                    .help("Nieuw uitje (⌘N)")
                    .disabled(!model.canOrganize)
            }
        }
        .sheet(isPresented: $adding) { NewOutingSheet() }
        .onChange(of: model.newRequest) { adding = true }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .onChange(of: model.query) { if !model.query.isEmpty, model.open != nil { model.close() } }
        .onKeyPress(.escape) {
            if searchFocused { searchFocused = false; model.query = ""; return .handled }
            guard model.open != nil || !model.query.isEmpty else { return .ignored }
            model.escape()
            return .handled
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast.message)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
        .overlay { ConfettiBurst(trigger: model.lastChange?.kind == .allDone ? model.lastChange?.id : nil) }
        .safeAreaInset(edge: .top, spacing: 0) {
            UpdateBanner(appName: "Hogsmeade") { (NSApp.delegate as? AppDelegate)?.restart() }
        }
    }

    private func shareText(_ outing: Outing) -> String {
        [outing.title, OutingFormat.when(outing), OutingFormat.whereLines(outing).joined(separator: ", "), outing.url]
            .compactMap { $0 }.joined(separator: "\n")
    }
}

/// Binnenkort and Geweest, then who goes and what kind, each a filter.
struct Sidebar: View {
    @Environment(OutingsModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                row("Binnenkort", "sparkles", count: model.upcoming.count, selected: model.page == .upcoming && model.filter == nil) {
                    model.page = .upcoming
                    model.filter = nil
                    model.close()
                }
                row("Geweest", "calendar", count: model.past.count, selected: model.page == .past) {
                    model.page = .past
                    model.filter = nil
                    model.close()
                }
            }
            if !model.people.isEmpty {
                Section("Wie gaat") {
                    ForEach(model.people) { person in
                        let selected = model.filter == .person(person.id) && model.page == .upcoming
                        Button {
                            model.page = .upcoming
                            model.filter = selected ? nil : .person(person.id)
                            model.close()
                        } label: {
                            HStack(spacing: 9) {
                                Avatar(person.name, size: 18)
                                Text(person.name).lineLimit(1)
                                Spacer()
                                SidebarCount(count: model.count(for: person))
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selected ? BurrowColor.hogsmeade.opacity(0.18) : nil)
                    }
                }
            }
            if !model.kinds.isEmpty {
                Section("Soort") {
                    ForEach(model.kinds, id: \.key) { kind in
                        let selected = model.filter == .kind(kind.key) && model.page == .upcoming
                        row(kind.label, Outing.symbol(forKind: kind.key), count: kind.count, selected: selected) {
                            model.page = .upcoming
                            model.filter = selected ? nil : .kind(kind.key)
                            model.close()
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            ConnectionBadge(
                host: model.connection?.serverURL.host() ?? "", detail: "Ingelogd als \(model.myName)",
                reachable: model.reachability.isReachable, busy: model.isLoading, appName: "Hogsmeade")
            .padding(10)
        }
    }

    private func row(_ title: String, _ icon: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 18)
                Text(title).lineLimit(1)
                Spacer()
                if count > 0 { SidebarCount(count: count) }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? BurrowColor.hogsmeade.opacity(0.18) : nil)
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
