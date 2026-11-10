import AppKit
import Foundation
import Observation

/// Lumos's state and every action its views take: the page, the filters,
/// the cursor over the cards, the pages over them and where focus returns
/// to, the Bibliotheek's selection, the trailer, and one undo stack for
/// the keyboard and the status bar. A state machine without a window, so
/// the tests drive it like the keyboard does.
@MainActor
@Observable
public final class LumosModel {
    public enum Page: String, CaseIterable, Sendable {
        case discover, list, library
    }

    public enum Focus: Sendable {
        case content, inspector, search
    }

    /// Ontdekken's first filter.
    public enum Kind: String, CaseIterable, Sendable {
        case all, movie, tv

        public var type: MediaType? { self == .all ? nil : MediaType(rawValue: rawValue) }
        public var label: String {
            switch self {
            case .all: "Alles"
            case .movie: "Films"
            case .tv: "Series"
            }
        }
    }

    /// "Voor jullie" shows the rows; every other sort is a grid that loads on.
    public enum Sort: String, CaseIterable, Sendable {
        case forYou, popular, new, upcoming, top, gems

        var browse: BrowseSort {
            switch self {
            case .forYou, .popular: .popular
            case .new: .new
            case .upcoming: .upcoming
            case .top: .top
            case .gems: .gems
            }
        }
    }

    /// Tonight's mood narrows by genre and trait, never by length. It heads
    /// the Genre menu.
    public enum Mood: String, CaseIterable, Sendable {
        case light = "Luchtig"
        case tense = "Spannend"
        case calm = "Rustig"

        public func matches(_ title: TitleSummary) -> Bool {
            let (genres, traits): ([String], [String]) =
                switch self {
                case .light: (["Komedie", "Romantiek", "Animatie", "Avontuur"], ["Warm", "Absurd", "Droge humor"])
                case .tense: (["Thriller", "Sciencefiction", "Misdaad", "Horror"], ["Mysterie", "Whodunit", "Spionage", "Hoog tempo"])
                case .calm: (["Drama", "Documentaire"], ["Rustig tempo", "Melancholisch", "Dagelijks leven", "Natuur"])
                }
            return title.genres.contains(where: genres.contains) || title.traits.contains(where: traits.contains)
        }
    }

    public enum GenreChoice: Hashable, Sendable {
        case mood(Mood)
        case genre(String)
    }

    /// Ontdekken's row of filters.
    public struct Filter: Equatable, Sendable {
        public var kind: Kind = .all
        public var sort: Sort = .forYou
        public var genre: GenreChoice?
        public var decade: Int?
        public var dutch = false
        public init() {}

        /// Without a filter the page is rows; any filter makes it a grid.
        public var plain: Bool { sort == .forYou && genre == nil && decade == nil && !dutch }
        var mood: Mood? { if case .mood(let mood) = genre { mood } else { nil } }
        var genreName: String? { if case .genre(let name) = genre { name } else { nil } }
    }

    /// The Bibliotheek's segments.
    public enum Shelf: String, CaseIterable, Sendable {
        case all, movie, tv, busy
    }

    public enum WatchedFilter: String, CaseIterable, Sendable {
        case all, together, partly, none

        public var label: String {
            switch self {
            case .all: "Alles"
            case .together: "Samen gezien"
            case .partly: "Eén van ons, of half"
            case .none: "Niet gezien"
            }
        }
    }

    public struct Toast: Equatable, Sendable {
        public var message: String
        public var canUndo: Bool
        public var id = UUID()
    }

    public struct ChangeNote: Equatable, Sendable {
        public enum Kind: Sendable { case listed, unlisted, passed, seen, restored, tuned, undone, played, deleted }

        public var kind: Kind
        public var ref: TitleRef?
        public var scope: ListScope
        public var id = UUID()
    }

    struct UndoEntry {
        var changeId: String
        var label: String
        var cursor: CardID?
    }

    public static let passReasons = ["Niet ons ding", "Liever een andere avond", "Eén van ons wil niet"]
    /// The "Niet nu" menu: no reason first, so Enter takes it.
    public static let reasonOptions = ["Zonder reden", "Al gezien"] + passReasons
    /// The rows of `/rows` that Ontdekken shows above the Zoeker's.
    static let ownRows: Set<String> = ["continue", "tonight", "mine-not-shared", "like"]

    public private(set) var connection: Connection?
    public private(set) var profile: Profile?
    public private(set) var status: LumosStatus?
    public var error: String?
    public let reachability: ServerReachability

    public var scope: ListScope = .shared {
        didSet { if oldValue != scope { Task { await reload() } } }
    }
    public private(set) var page: Page = .discover
    /// Searches the page you are on: the catalogue, the list or the Bibliotheek.
    public var query = "" {
        didSet { if oldValue != query { queryChanged() } }
    }
    public private(set) var filter = Filter()
    /// Genres per kind, as the catalogue names them.
    public private(set) var genres: [MediaType: [Genre]] = [:]
    /// What the page shows.
    public private(set) var loaded: [TitleRow] = []
    public private(set) var searchCredits: [Credit] = []
    public private(set) var listCount = 0
    public private(set) var isLoading = false
    /// The surprise rows; a new seed reshuffles them.
    public private(set) var exploreSeed = Int.random(in: 1...999_999)
    public private(set) var loadingMore = false
    private var gridPages: [MediaType: (page: Int, total: Int)] = [:]

    /// The Bibliotheek: what the media server is busy with, what it holds, the disk.
    public private(set) var manageAnswer: ManageResponse?
    public var shelf: Shelf = .all
    public var watchedFilter: WatchedFilter = .all
    public var librarySort: LibrarySort = .newest
    public var librarySelection: Set<TitleRef> = []
    public var libraryInspector = true
    /// The question before a delete; nil when none is asked.
    public var deleteRequest: DeleteRequest?
    /// The last thing done was a delete, which Z cannot take back.
    private var lastWasDelete = false

    /// Smaak and Overgeslagen in the settings, for both scopes.
    public private(set) var settingsVerdicts: [Verdict] = []

    public private(set) var cursor: CardID?
    public var focus: Focus = .content
    public private(set) var navigator = CardNavigator()
    private var gridColumns: [String: Int] = [:]

    /// A page over the page: a title, or a person, with the way back.
    public enum Place: Hashable, Sendable {
        case title(TitleRef)
        case person(String)
    }

    /// The pages on top; Esc goes back one, empty is the page itself.
    public private(set) var stack: [Place] = []
    private var inspectorOrigin: CardID?
    /// The title whose page is on top, if a title is.
    public var inspected: TitleRef? {
        if case .title(let ref) = stack.last { return ref }
        return nil
    }
    public var openPerson: String? {
        if case .person(let id) = stack.last { return id }
        return nil
    }
    struct DetailEntry {
        var detail: TitleDetail
        var similar: [TitleSummary]
        var at: Date
        var fresh: Bool { Date().timeIntervalSince(at) < LumosModel.detailLife }
    }
    /// Details once loaded stay, so a page opens at once a second time and
    /// the cursor's neighbour is already there (`prefetch`).
    private var details: [TitleRef: DetailEntry] = [:]
    private var detailOrder: [TitleRef] = []
    private var prefetching: Set<TitleRef> = []
    private var prefetchTask: Task<Void, Never>?
    public var detail: TitleDetail? { inspected.flatMap { details[$0]?.detail } }
    public var similar: [TitleSummary] { inspected.flatMap { details[$0]?.similar } ?? [] }

    public struct PersonPage: Sendable, Equatable {
        public var id: String
        public var name: String
        public var person: PersonDetail?
        public var titles: [TitleSummary]
    }
    private var people: [String: PersonPage] = [:]
    public var personPage: PersonPage? { openPerson.flatMap { people[$0] } }
    public private(set) var personLoading = false

    public private(set) var player: TrailerPlayback?
    /// Where the open title can be watched; nil until Jellyfin has answered.
    public private(set) var watchInfo: WatchInfo?
    /// The title whose choice of screens is open (K with several screens).
    public var screenMenu: TitleRef?
    /// Opens the title's page in the browser; the tests capture it.
    public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The card whose "Niet nu" menu is open, and the highlighted choice.
    public var reasonMenu: TitleRef? {
        didSet { if oldValue != reasonMenu { reasonChoice = 0 } }
    }
    public private(set) var reasonChoice = 0
    /// What the status bar says.
    public private(set) var toast: Toast?
    /// What just happened, for a face that wants to react to it.
    public private(set) var lastChange: ChangeNote?
    private var undoStack: [UndoEntry] = []
    public var searchFocusRequest = 0

    private let store: ConnectionStore
    private let makeClient: @Sendable (Connection) -> APIClient
    /// Where the last Ontdekken rows are kept, so the window opens full
    /// before the server has answered; nil keeps nothing (tests).
    private let cacheDirectory: URL?
    private var eventsTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    /// Off in tests, so the status bar keeps its line.
    var toastSeconds: Double? = 6

    public init(
        store: ConnectionStore = ConnectionStore(app: "lumos"),
        makeClient: @escaping @Sendable (Connection) -> APIClient = { APIClient(baseURL: $0.serverURL, token: $0.token) },
        connection: Connection? = nil,
        reachability: ServerReachability = ServerReachability(),
        cacheDirectory: URL? = nil
    ) {
        self.store = store
        self.makeClient = makeClient
        self.reachability = reachability
        self.cacheDirectory = cacheDirectory
        // LUMOS_SERVER and LUMOS_KEY connect without the Keychain, for demos
        // and automated runs against a development server.
        let environment = ProcessInfo.processInfo.environment
        if connection == nil, let server = environment["LUMOS_SERVER"].flatMap(URL.init(string:)),
           let key = environment["LUMOS_KEY"] {
            self.connection = Connection(serverURL: server, token: key)
        } else {
            self.connection = connection ?? store.load()
        }
        reachability.probe = { [weak self] in await self?.serverAnswers() ?? false }
        reachability.onRegained = { [weak self] in await self?.reload() }
    }

    public var api: APIClient? { connection.map(makeClient) }

    public var isFixture: Bool { status?.dataOrigin == .fixture }
    public var myName: String { profile?.person.name ?? "Ik" }
    /// The server has Jellyfin, so what is on Dobby can be watched.
    public var canWatch: Bool { status?.watch == true }
    /// Deleting files is for a household admin; no bot can hold that right.
    public var canDelete: Bool { profile?.isAdmin == true }
    public var listName: String { scope == .shared ? "Onze lijst" : "Jouw lijst" }

    // MARK: Connecting

    public func connect(serverURL: URL, token: String) async throws {
        let candidate = Connection(serverURL: serverURL, token: token)
        profile = try await makeClient(candidate).profile()
        try store.save(candidate)
        connection = candidate
        await start()
    }

    public func logout() {
        eventsTask?.cancel()
        store.clear()
        connection = nil
        profile = nil
        loaded = []
        manageAnswer = nil
        details.removeAll()
        detailOrder.removeAll()
        people.removeAll()
        closeInspector()
    }

    public func start() async {
        guard let api else { return }
        if loaded.isEmpty, page == .discover, let rows = readSnapshot() {
            loaded = rows
            layout()
        }
        do {
            async let profile = api.profile()
            async let status = api.lumosStatus()
            self.profile = try await profile
            self.status = try await status
        } catch APIError.unauthorized {
            logout()
            error = APIError.unauthorized.errorDescription
            return
        } catch {
            report(error, quiet: true)
            return
        }
        await reload()
        Task { await loadGenres() }
        if page != .library { Task { await refreshLibrary() } }
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            let reachability = self?.reachability
            let connected: @Sendable (Bool) -> Void = { up in
                Task { @MainActor in up ? await reachability?.answered() : reachability?.lost() }
            }
            guard let stream = self?.api?.events(connected: connected) else { return }
            for await event in stream {
                switch event.type {
                case "lumos.changed": await self?.reload()
                // A setting such as lumos.enabled changed somewhere: who we are and the status again.
                case "settings.changed": await self?.refreshProfile()
                default: break
                }
            }
        }
    }

    func refreshProfile() async {
        guard let api else { return }
        async let profile = api.profile()
        async let status = api.lumosStatus()
        if let profile = try? await profile { self.profile = profile }
        if let status = try? await status { self.status = status }
    }

    func serverAnswers() async -> Bool {
        guard let api else { return false }
        do {
            _ = try await api.profile()
            return true
        } catch {
            return !APIError.isTransient(error)
        }
    }

    func report(_ error: any Error, quiet: Bool = false) {
        if APIError.isTransient(error) {
            reachability.lost()
            if quiet { return }
        }
        self.error = APIError.describe(error)
    }

    // MARK: Pages

    public var title: String {
        switch page {
        case .discover: "Ontdekken"
        case .list: listName
        case .library: "Bibliotheek"
        }
    }

    public var subtitle: String {
        switch page {
        case .discover:
            if !queryText.isEmpty { return "Zoeken in films en series" }
            return [filter.kind == .all ? "Films en series" : filter.kind.label, filter.plain ? nil : filterLine]
                .compactMap { $0 }.joined(separator: " · ")
        case .list:
            return listCount == 1 ? "1 titel" : "\(listCount) titels"
        case .library:
            let selected = selectedItems
            if !selected.isEmpty {
                return "\(selected.count) geselecteerd · \(Bytes.text(selected.compactMap(\.sizeBytes).reduce(0, +)))"
            }
            let all = manageAnswer?.library ?? []
            let size = all.compactMap(\.sizeBytes).reduce(0, +)
            return "\(all.count) titels" + (size > 0 ? " · \(Bytes.text(size))" : "")
        }
    }

    public var searchPrompt: String {
        switch page {
        case .discover: "Zoek"
        case .list: "Zoek in \(listName.lowercased())"
        case .library: "Zoek in Bibliotheek"
        }
    }

    /// "Best beoordeeld · Komedie · jaren 90 · Nederlands"
    public var filterLine: String {
        [filter.sort == .forYou ? nil : sortLabel(filter.sort), genreLabel, filter.decade.map { "jaren \(String($0).suffix(2))" },
         filter.dutch ? "Nederlands" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    public func sortLabel(_ sort: Sort) -> String {
        switch sort {
        case .forYou: scope == .shared ? "Voor jullie" : "Voor jou"
        case .popular: "Populair"
        case .new: "Nieuw"
        case .upcoming: "Binnenkort"
        case .top: "Best beoordeeld"
        case .gems: "Verborgen parels"
        }
    }

    public var genreLabel: String? {
        switch filter.genre {
        case .mood(let mood): mood.rawValue
        case .genre(let name): name
        case nil: nil
        }
    }

    /// The genre names for the Genre menu: those of the kind, or of both.
    public var genreNames: [String] {
        let lists = filter.kind.type.map { [genres[$0] ?? []] } ?? [genres[.movie] ?? [], genres[.tv] ?? []]
        var names: [String] = []
        for genre in lists.joined() where !names.contains(genre.name) { names.append(genre.name) }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func show(_ page: Page) async {
        // The sidebar always lands on the page, whatever was open over it.
        if !stack.isEmpty { closeInspector(restoreFocus: false) }
        guard page != self.page || loaded.isEmpty else { return }
        searchTask?.cancel()
        self.page = page
        if !query.isEmpty { query = "" }
        cursor = nil
        librarySelection = []
        await reload()
    }

    /// ⌘4 and ⌘5: Ontdekken with only films or only series.
    public func showDiscover(_ kind: Kind) async {
        if page != .discover || !stack.isEmpty {
            filter.kind = kind
            await show(.discover)
        } else {
            await setFilter { $0.kind = kind }
        }
    }

    public func setFilter(_ change: (inout Filter) -> Void) async {
        var next = filter
        change(&next)
        guard next != filter else { return }
        filter = next
        cursor = nil
        await reload()
    }

    /// Verras me (V): the filters off, and new surprise rows.
    public func surprise() async {
        exploreSeed = Int.random(in: 1...999_999)
        let kind = filter.kind
        filter = Filter()
        filter.kind = kind
        if !query.isEmpty { query = "" }
        cursor = nil
        if page != .discover || !stack.isEmpty { await show(.discover) } else { await reload() }
    }

    /// The rows on screen: the list page narrowed by the search.
    public var rows: [TitleRow] {
        guard page == .list, !queryText.isEmpty else { return loaded }
        return loaded.compactMap { row in
            var row = row
            row.items = row.items.filter { Self.matches($0, queryText) }
            return row.items.isEmpty && row.key != "list" ? nil : row
        }
    }

    var queryText: String { query.trimmingCharacters(in: .whitespaces) }

    static func matches(_ title: TitleSummary, _ text: String) -> Bool {
        let haystack = ([title.title, title.year.map(String.init) ?? ""] + title.genres + title.traits).joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(text)
    }

    public func reload() async {
        guard let api else { return }
        isLoading = true
        defer { isLoading = false }
        // Lists and verdicts change what every detail says, so they load
        // again; the old ones stay meanwhile, so an open page keeps its place.
        for ref in details.keys { details[ref]?.at = .distantPast }
        do {
            async let listCount = countList(api)
            switch page {
            case .discover:
                try await loadDiscover(api)
            case .list:
                let list = try await api.list(scope).items.map(\.title)
                var rows = [TitleRow(
                    key: "list", title: "", items: list,
                    empty: "Nog niets op de lijst.", grid: true)]
                if scope == .shared {
                    let mine = try await api.list(.mine).items.map(\.title).filter { !$0.onShared }
                    if !mine.isEmpty {
                        rows.append(TitleRow(
                            key: "mine-not-shared", title: "Op jouw lijst, nog niet samen",
                            subtitle: "alleen jij ziet deze rij", items: mine, grid: true))
                    }
                }
                loaded = rows
            case .library:
                loaded = []
                try await loadLibrary(api)
            }
            self.listCount = try await listCount ?? loaded.first?.items.count ?? 0
            error = nil
        } catch is CancellationError {
        } catch {
            report(error, quiet: true)
        }
        layout()
        if let inspected { await loadDetail(inspected) }
    }

    private func countList(_ api: APIClient) async throws -> Int? {
        if page == .list { return nil }
        return try await api.list(scope).items.count
    }

    // MARK: Ontdekken

    private func loadDiscover(_ api: APIClient) async throws {
        searchCredits = []
        gridPages = [:]
        let text = queryText
        if !text.isEmpty {
            let found = try await api.search(titles: text, scope: scope)
            guard text == queryText else { return }
            let items = found.hits.map { hit -> TitleSummary in
                var title = hit.title
                title.match = hit.why
                return title
            }.filter(keeps)
            searchCredits = found.credits
            loaded = [TitleRow(key: "search", title: "Resultaten voor ‘\(text)’", subtitle: Self.count(items.count), items: items, grid: true)]
            return
        }
        if filter.sort == .forYou, filter.genreName == nil, filter.decade == nil, !filter.dutch {
            let rows = try await discoverRows(api)
            if let mood = filter.mood {
                var seen = Set<TitleRef>()
                let items = rows.flatMap(\.items).filter { seen.insert($0.ref).inserted && mood.matches($0) }
                loaded = [TitleRow(key: "grid", title: mood.rawValue, subtitle: Self.count(items.count), items: items, grid: true)]
            } else {
                loaded = rows
                if filter.kind == .all { writeSnapshot(rows) }
            }
            return
        }
        let items = try await browsePage(api, page: 1)
        loaded = [TitleRow(key: "grid", title: filter.kind == .all ? "Films en series" : filter.kind.label, subtitle: nil, items: items, grid: true)]
    }

    /// `/rows` for the household's own rows, then the Zoeker's.
    private func discoverRows(_ api: APIClient) async throws -> [TitleRow] {
        async let own = api.rows(scope: scope, type: filter.kind.type)
        async let more = api.explore(scope: scope, seed: exploreSeed, type: filter.kind.type)
        let rows = try await own.rows.filter { Self.ownRows.contains($0.key) }
        let explore = (try? await more.rows) ?? []
        return rows + explore
    }

    /// A page of the shop's shelves for the kind, or both kinds side by side.
    private func browsePage(_ api: APIClient, page: Int) async throws -> [TitleSummary] {
        let types = filter.kind.type.map { [$0] } ?? [.movie, .tv]
        var answers: [[TitleSummary]] = []
        for type in types {
            if page > 1, let known = gridPages[type], known.page >= known.total { continue }
            var genre: String?
            if let name = filter.genreName {
                guard let id = genres[type]?.first(where: { $0.name == name })?.id else { continue }
                genre = id
            }
            let found = try await api.browse(
                type: type, sort: filter.sort.browse, genre: genre, dutch: filter.dutch, decade: filter.decade, page: page, scope: scope)
            gridPages[type] = (page, found.totalPages)
            if genres[type]?.isEmpty ?? true { genres[type] = found.genres }
            answers.append(found.items.filter(keeps))
        }
        // Films and series take turns, so neither kind hides behind the other.
        var merged: [TitleSummary] = []
        for index in 0..<(answers.map(\.count).max() ?? 0) {
            for answer in answers where index < answer.count { merged.append(answer[index]) }
        }
        return merged
    }

    private func keeps(_ title: TitleSummary) -> Bool {
        (filter.kind.type == nil || title.mediaType == filter.kind.type) && (filter.mood?.matches(title) ?? true)
    }

    /// The next page of the grid, appended; the last page stops it.
    public func loadMore() async {
        guard let api, page == .discover, !loadingMore, !gridPages.isEmpty,
              let index = loaded.firstIndex(where: { $0.key == "grid" }) else { return }
        let next = (gridPages.values.map(\.page).min() ?? 1) + 1
        guard gridPages.values.contains(where: { $0.page < $0.total }) else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let items = try await browsePage(api, page: next)
            guard page == .discover, loaded.indices.contains(index) else { return }
            let known = Set(loaded[index].items.map(\.ref))
            loaded[index].items += items.filter { !known.contains($0.ref) }
            layout()
        } catch {
            report(error, quiet: true)
        }
    }

    public var canLoadMore: Bool { gridPages.values.contains { $0.page < $0.total } }

    func loadGenres() async {
        guard let api, genres.isEmpty, status?.dataOrigin != nil else { return }
        for type in [MediaType.movie, .tv] {
            if let found = try? await api.browse(type: type, sort: .popular, scope: scope) { genres[type] = found.genres }
        }
    }

    static func count(_ n: Int) -> String { n == 1 ? "1 titel" : "\(n) titels" }

    // MARK: The snapshot on disk

    private var snapshotURL: URL? {
        cacheDirectory?.appendingPathComponent("rows-\(scope.rawValue).json")
    }

    private func readSnapshot() -> [TitleRow]? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? APIClient.decoder.decode([TitleRow].self, from: data)
    }

    private func writeSnapshot(_ rows: [TitleRow]) {
        guard let url = snapshotURL, let data = try? JSONEncoder().encode(rows) else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Layout and the cursor

    /// The view tells how many posters fit in a line of a grid.
    public func setColumns(_ columns: Int, for row: String) {
        guard gridColumns[row] != columns else { return }
        gridColumns[row] = columns
        layout()
    }

    func layout() {
        let previous = navigator
        var lines: [CardLine] = []
        for row in rows where !row.items.isEmpty {
            let refs = row.items.map(\.ref)
            if row.grid {
                lines += CardNavigator.gridLines(row: row.key, cards: refs, columns: gridColumns[row.key] ?? 6, width: row.style.cardStep)
            } else {
                lines.append(CardLine(key: row.key, row: row.key, cards: refs, width: row.style.cardStep))
            }
        }
        var next = CardNavigator(lines: lines)
        next.remembered = previous.remembered
        navigator = next
        // A page with cards always has one under the cursor.
        cursor = next.keep(cursor, previous: previous) ?? next.first
    }

    public func summary(_ ref: TitleRef) -> TitleSummary? {
        if let known = details[ref], known.fresh { return known.detail.summary }
        for row in loaded { if let found = row.items.first(where: { $0.ref == ref }) { return found } }
        return libraryItem(ref)?.title
            ?? settingsVerdicts.first(where: { $0.title.ref == ref })?.title
            ?? similar.first(where: { $0.ref == ref })
            ?? personPage?.titles.first(where: { $0.ref == ref })
            ?? details[ref]?.detail.summary
    }

    /// What J, N, T and K act on: the open page, the card under the cursor,
    /// or the one title selected in the Bibliotheek.
    public var target: TitleRef? {
        if let inspected { return inspected }
        if page == .library { return librarySelection.count == 1 ? librarySelection.first : nil }
        return cursor?.ref
    }

    public func select(_ card: CardID) {
        cursor = card
        focus = .content
        if let (l, c) = navigator.position(of: card) { navigator.remembered[navigator.lines[l].key] = c }
    }

    public func move(_ move: Move) {
        guard let next = navigator.move(move, from: cursor) else { return }
        cursor = next
        // A title page opened from the rows follows the keyboard.
        if inspected != nil, stack.count == 1, next.ref != inspected, page != .library {
            open(next.ref, from: next, focusInside: false)
        } else {
            prefetch(next.ref)
        }
        // The grid's last lines: more, before the keyboard gets there.
        if let line = navigator.position(of: next)?.line, line >= navigator.lines.count - 2, loaded.contains(where: { $0.key == "grid" }) {
            Task { await loadMore() }
        }
    }

    // MARK: The pages over the page

    public var inspectorShown: Bool { !stack.isEmpty }

    /// Opens a title's page. From a card or a table row it replaces what was
    /// open; from inside a page (Meer zoals dit, a person's work) it goes on
    /// top, so Esc comes back there.
    public func open(_ ref: TitleRef, from card: CardID? = nil, focusInside: Bool) {
        if inspected != ref {
            stopTrailer()
            watchInfo = nil
            screenMenu = nil
            detailTask?.cancel()
            watchTask?.cancel()
            if card != nil || stack.isEmpty {
                stack = [.title(ref)]
            } else {
                stack.append(.title(ref))
            }
            detailTask = Task { await loadDetail(ref) }
        }
        if let card { inspectorOrigin = card }
        focus = focusInside ? .inspector : .content
    }

    public func openPerson(_ id: String, name: String? = nil) {
        stopTrailer()
        if people[id] == nil, let name { people[id] = PersonPage(id: id, name: name, person: nil, titles: []) }
        stack.append(.person(id))
        focus = .inspector
        Task { await loadPerson(id) }
    }

    /// The navigation stack's back button and swipe set the path itself.
    public func setStack(_ path: [Place]) {
        while stack.count > path.count { back() }
    }

    /// Esc, ⌘[ or the back button: one page back; the page when it was the last.
    public func back() {
        guard !stack.isEmpty else { return }
        stopTrailer()
        screenMenu = nil
        stack.removeLast()
        if stack.isEmpty {
            closeInspector()
        } else if let ref = inspected {
            watchInfo = nil
            detailTask = Task { await loadDetail(ref) }
        }
    }

    /// Space: shows or hides the title's page.
    public func toggleInspector() {
        guard let cursor else { return }
        if inspected == cursor.ref { closeInspector(restoreFocus: false) } else { open(cursor.ref, from: cursor, focusInside: false) }
    }

    public func closeInspector(restoreFocus: Bool = true) {
        stopTrailer()
        detailTask?.cancel()
        watchTask?.cancel()
        stack = []
        watchInfo = nil
        screenMenu = nil
        if restoreFocus, let origin = inspectorOrigin {
            cursor = navigator.position(of: origin) != nil ? origin : navigator.keep(origin, previous: navigator)
        }
        inspectorOrigin = nil
        focus = .content
    }

    public var detailTaskForTests: Task<Void, Never>? { detailTask }

    /// How long a loaded detail stays good; lists and verdicts clear it anyway.
    nonisolated static let detailLife: TimeInterval = 300

    func loadDetail(_ ref: TitleRef) async {
        guard let api else { return }
        if let hit = details[ref], hit.fresh {
            followProgress(of: hit.detail)
            followWatch(of: hit.detail)
            return
        }
        do {
            async let detailAnswer = api.title(ref, scope: scope)
            async let similarAnswer = api.similar(to: ref, scope: scope).items
            let (loaded, similar) = try await (detailAnswer, similarAnswer)
            remember(ref, loaded, similar)
            guard inspected == ref else { return }
            followProgress(of: loaded)
            followWatch(of: loaded)
        } catch is CancellationError {
        } catch {
            if inspected == ref { report(error) }
        }
    }

    private func remember(_ ref: TitleRef, _ detail: TitleDetail, _ similar: [TitleSummary]) {
        details[ref] = DetailEntry(detail: detail, similar: Array(similar.prefix(18)), at: .now)
        detailOrder.removeAll { $0 == ref }
        detailOrder.append(ref)
        while detailOrder.count > 80 { details[detailOrder.removeFirst()] = nil }
    }

    /// Loads a title's page before it is asked for: the card under the
    /// cursor or the mouse, so Enter or a click shows it at once.
    public func prefetch(_ ref: TitleRef) {
        guard details[ref]?.fresh != true, !prefetching.contains(ref), let api else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, details[ref]?.fresh != true else { return }
            prefetching.insert(ref)
            defer { prefetching.remove(ref) }
            async let detailAnswer = api.title(ref, scope: scope)
            async let similarAnswer = api.similar(to: ref, scope: scope).items
            guard let loaded = try? await detailAnswer else { return }
            let similar = (try? await similarAnswer) ?? []
            remember(ref, loaded, similar)
            ImageLoaderHook.prefetch?([loaded.backdrop, loaded.poster].compactMap { $0 } + similar.compactMap(\.poster))
        }
    }

    public var isPrefetched: (TitleRef) -> Bool { { [self] in details[$0] != nil } }

    func loadPerson(_ id: String) async {
        guard let api else { return }
        if let known = people[id], known.person != nil { return }
        personLoading = true
        defer { personLoading = false }
        do {
            let found = try await api.credit(id, scope: scope)
            people[id] = PersonPage(id: id, name: found.credit.name, person: found.person, titles: found.titles)
        } catch {
            if openPerson == id { report(error) }
        }
    }

    /// After the details: where a title on Dobby can be watched. Asked
    /// apart, so a slow Jellyfin never holds the details back.
    private func followWatch(of detail: TitleDetail) {
        watchTask?.cancel()
        guard canWatch, let api, detail.availability.held else { return }
        let ref = detail.ref
        watchTask = Task { [weak self] in
            guard let info = try? await api.watch(ref), !Task.isCancelled, self?.inspected == ref else { return }
            self?.watchInfo = info
        }
    }

    public var watchTaskForTests: Task<Void, Never>? { watchTask }

    private var progressTask: Task<Void, Never>?
    var progressSeconds: Double? = 20

    /// Seerr tells nobody when a download moves on, so an open title that
    /// waits or downloads asks again now and then.
    private func followProgress(of detail: TitleDetail) {
        progressTask?.cancel()
        let busy = detail.request?.status == .pending || detail.availability == .downloading
            || (detail.request?.status == .sent && detail.availability == .requested)
        guard busy, let seconds = progressSeconds else { return }
        let ref = detail.ref
        progressTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.inspected == ref else { return }
            await self?.loadDetail(ref)
        }
    }

    // MARK: The Bibliotheek

    private var manageTask: Task<Void, Never>?

    private func loadLibrary(_ api: APIClient) async throws {
        guard status?.requests == true else {
            manageAnswer = nil
            return
        }
        manageAnswer = try await api.manage(scope: scope)
        librarySelection.formIntersection(Set(manageAnswer?.library.map(\.id) ?? []))
        followManage()
    }

    /// The sidebar's disk and count, also while another page is open.
    func refreshLibrary() async {
        guard let api, status?.requests == true else { return }
        if let answer = try? await api.manage(scope: scope) { manageAnswer = answer }
    }

    /// While something downloads or waits, the Bibliotheek looks again now and then.
    private func followManage() {
        manageTask?.cancel()
        guard page == .library, manageAnswer?.busy.isEmpty == false, let seconds = progressSeconds else { return }
        manageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, page == .library, let api else { return }
            if let answer = try? await api.manage(scope: scope) { manageAnswer = answer }
            followManage()
        }
    }

    public func libraryItem(_ ref: TitleRef) -> ManageItem? {
        manageAnswer.flatMap { answer in answer.library.first { $0.id == ref } ?? answer.busy.first { $0.id == ref } }
    }

    public var disk: DiskUse? {
        guard let answer = manageAnswer, let disk = answer.disk else { return nil }
        return DiskUse(disk: disk, library: answer.library, busy: answer.busy)
    }

    public var busyCount: Int { manageAnswer?.busy.count ?? 0 }

    /// The table: the shelf, the watched filter and the search, sorted.
    public var libraryRows: [LibraryRow] {
        let items = (manageAnswer?.library ?? []).filter { item in
            switch shelf {
            case .all, .busy: true
            case .movie: item.title.mediaType == .movie
            case .tv: item.title.mediaType == .tv
            }
        }.filter { item in
            watchedFilter == .all || item.watched.kind.rawValue == watchedFilter.rawValue
        }.filter { queryText.isEmpty || Self.matches($0.title, queryText) }
        return librarySort.sorted(items.map(LibraryRow.init))
    }

    public var busyItems: [ManageItem] {
        (manageAnswer?.busy ?? []).filter { queryText.isEmpty || Self.matches($0.title, queryText) }
    }

    public var selectedItems: [ManageItem] {
        (manageAnswer?.library ?? []).filter { librarySelection.contains($0.id) }
    }

    /// What "Ruimte maken" selects: seen together, large, on nobody's list, largest first.
    public var spaceCandidates: [ManageItem] {
        (manageAnswer?.library ?? []).filter { $0.spaceCandidate == true }.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }

    public func makeRoom() {
        if !stack.isEmpty { closeInspector(restoreFocus: false) }
        if page != .library {
            page = .library
            loaded = []
        }
        shelf = .all
        watchedFilter = .all
        librarySort = .largest
        if !query.isEmpty { query = "" }
        librarySelection = Set(spaceCandidates.map(\.id))
    }

    /// ⌫: asks first, and only for what Radarr or Sonarr manages.
    public func askDelete(_ refs: [TitleRef]? = nil) {
        guard canDelete else { return }
        let wanted = refs ?? (page == .library && stack.isEmpty ? Array(librarySelection) : target.map { [$0] } ?? [])
        let items = wanted.compactMap { ref in manageAnswer?.library.first { $0.id == ref } }
        let removable = items.filter(\.removable)
        guard !removable.isEmpty else {
            if let first = items.first { show(first.lockReason) }
            return
        }
        deleteRequest = DeleteRequest(items: removable, kept: items.count - removable.count)
    }

    public var canDeleteTarget: Bool {
        guard canDelete else { return false }
        let refs = page == .library && stack.isEmpty ? Array(librarySelection) : target.map { [$0] } ?? []
        return refs.contains { ref in manageAnswer?.library.first { $0.id == ref }?.removable == true }
    }

    /// Deletes what the question named, one title at a time.
    public func confirmDelete() async {
        guard let request = deleteRequest, let api, canDelete else { return }
        deleteRequest = nil
        var done: [ManageItem] = []
        for item in request.items {
            do {
                try await api.removeFromLibrary(item.id)
                done.append(item)
            } catch {
                report(error)
                break
            }
        }
        guard !done.isEmpty else { return }
        let bytes = done.compactMap(\.sizeBytes).reduce(0, +)
        let what = done.count == 1 ? "‘\(done[0].title.title)’ is" : "\(done.count) titels zijn"
        show("\(what) verwijderd\(bytes > 0 ? ", \(Bytes.text(bytes)) vrijgemaakt" : ""). Dit kan niet worden hersteld.")
        lastWasDelete = true
        lastChange = ChangeNote(kind: .deleted, ref: done.first?.id, scope: scope)
        librarySelection.subtract(done.map(\.id))
        if let inspected, done.contains(where: { $0.id == inspected }) { closeInspector(restoreFocus: false) }
        await reload()
        if page != .library { await refreshLibrary() }
    }

    public func retryRequest(_ ref: TitleRef) async {
        guard let api else { return }
        do {
            try await api.retryRequest(ref)
            show("Lumos vraagt het opnieuw aan.")
            if inspected == ref { await loadDetail(ref) }
        } catch {
            report(error)
        }
    }

    /// Esc: the menu, then the trailer, then one page back, then the selection.
    public func escape() {
        if reasonMenu != nil {
            reasonMenu = nil
        } else if player != nil {
            stopTrailer()
        } else if !stack.isEmpty {
            back()
        } else if page == .library, !librarySelection.isEmpty {
            librarySelection = []
        }
    }

    // MARK: The trailer

    /// T: opens the title and starts the trailer.
    public func playTrailer(_ ref: TitleRef? = nil) async {
        guard let ref = ref ?? target else { return }
        if inspected != ref { open(ref, from: cursor?.ref == ref ? cursor : nil, focusInside: true) }
        await detailTask?.value
        guard inspected == ref, let trailer = detail?.trailer else {
            show("Geen trailer gekoppeld voor \(summary(ref)?.title ?? "deze titel").")
            return
        }
        player = TrailerPlayback(ref: ref, trailer: trailer)
    }

    public func stopTrailer() {
        player = nil
    }

    /// What the player view saw. A report about a title no longer open is
    /// stale and changes nothing.
    public func playerReported(_ status: TrailerPlayback.Status, for ref: TitleRef) {
        guard player?.ref == ref else { return }
        player?.status = status
    }

    // MARK: Watching

    /// K: starts a title on Dobby on the TV when one screen has Jellyfin
    /// open, opens it here when none has, and asks when several have. It
    /// picks up where the household stopped.
    public func watch(_ ref: TitleRef? = nil) async {
        guard let ref = ref ?? target else { return }
        guard canWatch else {
            show("Niet gekoppeld aan Jellyfin, dus kijken kan nog niet.")
            return
        }
        if inspected != ref { open(ref, from: cursor?.ref == ref ? cursor : nil, focusInside: true) }
        await detailTask?.value
        await watchTask?.value
        guard inspected == ref, let detail else { return }
        guard let info = watchInfo, info.web != nil else {
            show(detail.availability.held ? "Jellyfin heeft \(detail.title) niet gevonden." : "\(detail.title) staat nog niet op Dobby.")
            return
        }
        switch info.screens.count {
        case 0: watchHere(ref)
        case 1: await play(on: info.screens[0], ref)
        default: screenMenu = ref
        }
    }

    /// Opens the title's page in Jellyfin's web app, in the browser.
    public func watchHere(_ ref: TitleRef? = nil) {
        guard let ref = ref ?? inspected, inspected == ref, let web = watchInfo?.web, let url = URL(string: web) else { return }
        openURL(url)
        show("\(detail?.title ?? "De titel") opent in je browser.")
    }

    /// Tells the screen to play the title, and says only what the screen confirmed.
    public func play(on screen: Screen, _ ref: TitleRef? = nil) async {
        guard let api, let ref = ref ?? inspected else { return }
        screenMenu = nil
        let title = summary(ref)?.title ?? detail?.title ?? "De titel"
        show("Start \(title) op \(screen.name)…")
        do {
            let played = try await api.play(ref, on: screen.deviceId)
            let what = played.episode.map { "\(title) \($0.label)" } ?? title
            let from = played.startSeconds.map { " vanaf \(Clock.text($0))" } ?? ""
            show(played.confirmed
                ? "\(what) speelt op \(played.screen.name)\(from)."
                : "\(what) is gestart op \(played.screen.name)\(from); de tv meldt nog niets.")
            lastChange = ChangeNote(kind: .played, ref: ref, scope: scope)
        } catch {
            report(error)
        }
    }

    // MARK: Lists and verdicts

    private func perform(_ label: String, _ kind: ChangeNote.Kind, _ ref: TitleRef? = nil, undoable: Bool = true, _ work: (APIClient) async throws -> LumosChange) async {
        guard let api else { return }
        let at = cursor
        do {
            let change = try await work(api)
            if undoable { undoStack.append(UndoEntry(changeId: change.changeId, label: label, cursor: at)) }
            lastWasDelete = false
            lastChange = ChangeNote(kind: kind, ref: ref, scope: scope)
            show(label, canUndo: undoable)
            await reload()
            if page != .library, manageAnswer != nil { await refreshLibrary() }
            if !settingsVerdicts.isEmpty { await loadVerdicts() }
        } catch {
            report(error)
        }
    }

    /// J: on the list of the scope you are in, or off it again. `seasons`
    /// picks which seasons of a series are asked for; none means the first.
    public func toggleList(_ ref: TitleRef? = nil, seasons: [Int]? = nil) async {
        guard let ref = ref ?? target, let title = summary(ref) else { return }
        let list = listName.lowercased()
        if title.onList {
            await perform("\(title.title) van \(list) gehaald.", .unlisted, ref) { try await $0.removeFromList(ref, scope: scope) }
        } else {
            await addToList(ref, seasons: seasons)
        }
    }

    /// A poster or a row dropped on the list in the sidebar.
    public func addToList(_ ref: TitleRef, seasons: [Int]? = nil) async {
        guard let title = summary(ref), !title.onList else { return }
        let list = listName.lowercased()
        let requests = status?.requests == true && title.availability == .notRequested
        let which = seasons.map { Self.seasonsLabel($0) }.map { " (\($0))" } ?? ""
        let label = requests ? "\(title.title) staat op \(list) en wordt zo aangevraagd\(which)." : "\(title.title) staat op \(list)\(which)."
        await perform(label, .listed, ref) { try await $0.addToList(ref, scope: scope, seasons: seasons) }
    }

    /// "seizoen 1, 2" or "alle 4 seizoenen".
    public static func seasonsLabel(_ seasons: [Int], of total: Int? = nil) -> String {
        let sorted = seasons.sorted()
        if let total, total > 1, sorted == Array(1...total) { return "alle \(total) seizoenen" }
        return "seizoen " + sorted.map(String.init).joined(separator: ", ")
    }

    /// N: the reason menu on a card or a page; in the table straight away.
    public func askNotNow() async {
        guard let ref = target else { return }
        if page == .library, stack.isEmpty {
            await notNow(ref)
        } else {
            if inspected != nil { focus = .inspector }
            reasonMenu = ref
        }
    }

    /// N with a reason or none; "Al gezien" is its own kind and no dislike.
    public func notNow(_ ref: TitleRef? = nil, reason: String? = nil) async {
        reasonMenu = nil
        guard let ref = ref ?? target, let title = summary(ref) else { return }
        let label = reason.map { "Niet nu: \(title.title), \($0.lowercased())." } ?? "Niet nu: \(title.title)."
        await perform(label, .passed, ref) { try await $0.addVerdict(.notNow, ref, scope: scope, reason: reason) }
    }

    /// The menu's arrows; the keyboard stays where it was, the menu follows.
    public func moveReason(by step: Int) {
        let count = Self.reasonOptions.count
        reasonChoice = (reasonChoice + step + count) % count
    }

    public func chooseReason(_ index: Int? = nil) async {
        guard let ref = reasonMenu else { return }
        switch index ?? reasonChoice {
        case 0: await notNow(ref)
        case 1: await seen(ref)
        case let other: await notNow(ref, reason: Self.reasonOptions[other])
        }
    }

    public func seen(_ ref: TitleRef? = nil) async {
        reasonMenu = nil
        guard let ref = ref ?? target, let title = summary(ref) else { return }
        await perform("Al gezien: \(title.title).", .seen, ref) { try await $0.addVerdict(.seen, ref, scope: scope) }
    }

    public func restore(_ verdict: Verdict) async {
        await restore(verdictId: verdict.id, title: verdict.title.title)
    }

    public func restore(verdictId: String, title: String) async {
        await perform("\(title) kan weer voorgesteld worden.", .restored) { try await $0.undoVerdict(verdictId) }
    }

    /// "Meer zoals dit" or "Minder zoals dit"; choosing it again takes it back.
    public func taste(_ kind: VerdictKind, _ ref: TitleRef? = nil) async {
        guard let ref = ref ?? target, let title = summary(ref) else { return }
        if let current = title.taste, current.kind == kind {
            await perform("Bijstelling voor \(title.title) weggehaald.", .tuned, ref) { try await $0.undoVerdict(current.id) }
        } else {
            let word = kind == .moreLikeThis ? "Meer" : "Minder"
            await perform("\(word) zoals \(title.title).", .tuned, ref) { try await $0.addVerdict(kind, ref, scope: scope) }
        }
    }

    /// Smaak and Overgeslagen in the settings: the household's and your own.
    public func loadVerdicts() async {
        guard let api else { return }
        async let shared = api.verdicts(.shared).items
        async let mine = api.verdicts(.mine).items
        if let shared = try? await shared, let mine = try? await mine {
            settingsVerdicts = (shared + mine).sorted { $0.createdAt > $1.createdAt }
        }
    }

    public var canUndo: Bool { !undoStack.isEmpty && !lastWasDelete }

    /// Z or ⌘Z: the last change, exactly, and focus back where it was. A
    /// delete is never taken back: the files are gone.
    public func undo() async {
        if lastWasDelete {
            show("Verwijderen kan niet ongedaan worden; de bestanden zijn weg.")
            return
        }
        guard let entry = undoStack.popLast() else {
            show("Niets om ongedaan te maken.")
            return
        }
        guard let api else { return }
        do {
            _ = try await api.undo(change: entry.changeId)
            lastChange = ChangeNote(kind: .undone, ref: nil, scope: scope)
            show("Hersteld.")
            await reload()
            if !settingsVerdicts.isEmpty { await loadVerdicts() }
            if let at = entry.cursor, navigator.position(of: at) != nil { cursor = at }
        } catch {
            report(error)
        }
    }

    // MARK: Search

    public func requestSearchFocus() {
        searchFocusRequest += 1
        focus = .search
    }

    private func queryChanged() {
        // Typing while a title is open goes back to the page being searched.
        if !stack.isEmpty { closeInspector(restoreFocus: false) }
        searchTask?.cancel()
        switch page {
        case .discover:
            cursor = nil
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await reload()
            }
        case .list:
            layout()
        case .library:
            librarySelection.formIntersection(Set(libraryRows.map(\.id)))
        }
    }

    /// Return in the search field: to the first result.
    public func enterResults() {
        focus = .content
        cursor = navigator.first
    }

    // MARK: The status bar

    public func show(_ message: String, canUndo: Bool = false) {
        let next = Toast(message: message, canUndo: canUndo)
        toast = next
        toastTask?.cancel()
        guard let seconds = toastSeconds else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled, self?.toast?.id == next.id { self?.toast = nil }
        }
    }
}

extension TitleRow.Style {
    /// A card's width plus the gap, in points.
    public var cardWidth: Double { self == .wide ? 300 : 150 }
    public var cardStep: Double { cardWidth + 16 }
}

/// LumosUI's image loader warms its cache for a prefetched title; the model
/// itself knows no AppKit image loading.
public enum ImageLoaderHook {
    @MainActor public static var prefetch: (([String]) -> Void)?
}
