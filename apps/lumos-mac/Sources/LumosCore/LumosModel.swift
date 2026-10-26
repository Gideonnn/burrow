import AppKit
import Foundation
import Observation

/// Lumos's state and every action its views take: the page, the cursor over
/// the cards, the inspector and where focus returns to, the trailer, and one
/// undo stack for the keyboard and the toast. A state machine without a
/// window, so the tests drive it like the keyboard does.
@MainActor
@Observable
public final class LumosModel {
    public enum Page: String, CaseIterable, Sendable {
        case discover, list, movies, series, available, taste, passed, search
    }

    public enum Focus: Sendable {
        case content, inspector, search
    }

    /// Tonight's mood narrows the proposals by genre and trait, never by length.
    public enum Mood: String, CaseIterable, Sendable {
        case all = "Alles"
        case light = "Luchtig"
        case tense = "Spannend"
        case calm = "Rustig"

        public func matches(_ title: TitleSummary) -> Bool {
            if self == .all { return true }
            let (genres, traits): ([String], [String]) =
                switch self {
                case .all: ([], [])
                case .light: (["Komedie", "Romantiek", "Animatie"], ["Warm", "Absurd", "Droge humor"])
                case .tense: (["Thriller", "Sciencefiction", "Misdaad"], ["Mysterie", "Whodunit", "Spionage", "Hoog tempo"])
                case .calm: (["Drama", "Documentaire"], ["Rustig tempo", "Melancholisch", "Dagelijks leven", "Natuur"])
                }
            return title.genres.contains(where: genres.contains) || title.traits.contains(where: traits.contains)
        }
    }

    public struct Toast: Equatable, Sendable {
        public var message: String
        public var canUndo: Bool
        public var id = UUID()
    }

    public struct ChangeNote: Equatable, Sendable {
        public enum Kind: Sendable { case listed, unlisted, passed, seen, restored, tuned, undone, played }

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

    public private(set) var connection: Connection?
    public private(set) var profile: Profile?
    public private(set) var status: LumosStatus?
    public var error: String?
    public let reachability: ServerReachability

    public var scope: ListScope = .shared {
        didSet { if oldValue != scope { Task { await scopeChanged() } } }
    }
    public private(set) var page: Page = .discover
    private var pageBeforeSearch: Page = .discover
    public var query = "" {
        didSet { if oldValue != query { queryChanged() } }
    }
    public var mood: Mood = .all {
        didSet { if oldValue != mood { layout() } }
    }
    /// What the page shows, before the mood.
    public private(set) var loaded: [TitleRow] = []
    public private(set) var searchCredits: [Credit] = []
    public private(set) var verdictItems: [Verdict] = []
    public private(set) var listCount = 0
    public private(set) var passedCount = 0
    public private(set) var isLoading = false

    public private(set) var cursor: CardID?
    public var focus: Focus = .content
    public private(set) var navigator = CardNavigator()
    private var gridColumns: [String: Int] = [:]

    public private(set) var inspected: TitleRef?
    private var inspectorOrigin: CardID?
    public private(set) var detail: TitleDetail?
    public private(set) var similar: [TitleSummary] = []
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
    public private(set) var toast: Toast?
    /// What just happened, for a face that wants to celebrate or react to it.
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
    /// Off in tests, so a toast stays until the next one.
    var toastSeconds: Double? = 5

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
    /// The server has Jellyfin, so available titles can be watched.
    public var canWatch: Bool { status?.watch == true }

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
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            let reachability = self?.reachability
            let connected: @Sendable (Bool) -> Void = { up in
                Task { @MainActor in up ? await reachability?.answered() : reachability?.lost() }
            }
            guard let stream = self?.api?.events(connected: connected) else { return }
            for await event in stream where event.type == "lumos.changed" {
                await self?.reload()
            }
        }
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
        case .list: scope == .shared ? "Onze lijst" : "Jouw lijst"
        case .movies: "Films"
        case .series: "Series"
        case .available: "Klaar in Jellyfin"
        case .taste: "Smaak"
        case .passed: "Overgeslagen"
        case .search: "Zoeken"
        }
    }

    public var subtitle: String {
        switch page {
        case .discover: scope == .shared ? "Wat kijken jullie samen?" : "Voorstellen voor \(myName)"
        case .search: query.isEmpty ? "" : "Titel, maker, cast, genre of kenmerk"
        default: scope == .shared ? "Samen" : myName
        }
    }

    public func show(_ page: Page) async {
        if page != .search, self.page == .search { searchTask?.cancel(); query = "" }
        guard page != self.page || loaded.isEmpty else { return }
        self.page = page
        cursor = nil
        await reload()
    }

    /// The rows on screen: Ontdekken narrowed by the mood.
    public var rows: [TitleRow] {
        guard page == .discover, mood != .all else { return loaded }
        return loaded.compactMap { row in
            var row = row
            row.items = row.items.filter(mood.matches)
            if row.items.isEmpty, row.key == "tonight" { row.empty = "Niets past bij deze stemming. Kies Alles." }
            return row.items.isEmpty && row.empty == nil ? nil : row
        }
    }

    public func reload() async {
        guard let api else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // The counts for the sidebar come in alongside the page itself.
            async let passedCount = countPassed(api)
            async let listCount = countList(api)
            switch page {
            case .discover:
                loaded = try await api.rows(scope: scope).rows
                writeSnapshot(loaded)
            case .list:
                let list = try await api.list(scope).items.map(\.title)
                var rows = [TitleRow(
                    key: "list", title: scope == .shared ? "Onze lijst" : "Jouw lijst",
                    subtitle: "\(list.count) bewaard · Ja zet een titel hier, Niet nu haalt hem eraf", items: list,
                    empty: "Nog leeg. Bewaar titels in Ontdekken met J.", grid: true)]
                if scope == .shared {
                    let mine = try await api.list(.mine).items.map(\.title).filter { !$0.onShared }
                    if !mine.isEmpty {
                        rows.append(TitleRow(
                            key: "mine-not-shared", title: "Op jouw lijst, nog niet samen",
                            subtitle: "Samen kijken? Zet het op onze lijst met J", items: mine, grid: true))
                    }
                }
                loaded = rows
            case .movies, .series, .available:
                let items = try await api.titles(
                    scope: scope, type: page == .movies ? .movie : page == .series ? .tv : nil,
                    available: page == .available).items
                loaded = [TitleRow(key: "library-\(page.rawValue)", title: title, subtitle: "\(items.count) titels", items: items, grid: true)]
            case .passed, .taste:
                let all = try await api.verdicts(scope).items
                verdictItems = all.filter { $0.kind.isPass == (page == .passed) }
                loaded = []
            case .search:
                await runSearch()
            }
            self.passedCount = try await passedCount ?? verdictItems.count
            self.listCount = try await listCount ?? loaded.first?.items.count ?? 0
            error = nil
        } catch {
            report(error, quiet: true)
        }
        layout()
        if let inspected { await loadDetail(inspected) }
    }

    private func scopeChanged() async {
        await reload()
    }

    /// Nil when the page itself holds the count.
    private func countPassed(_ api: APIClient) async throws -> Int? {
        if page == .passed { return nil }
        return try await api.verdicts(scope).items.filter(\.kind.isPass).count
    }

    private func countList(_ api: APIClient) async throws -> Int? {
        if page == .list { return nil }
        return try await api.list(scope).items.count
    }

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
        if let detail, detail.ref == ref { return detail.summary }
        for row in loaded { if let found = row.items.first(where: { $0.ref == ref }) { return found } }
        return verdictItems.first(where: { $0.title.ref == ref })?.title ?? similar.first(where: { $0.ref == ref })
    }

    /// What J, N and T act on: the open title when focus is in the inspector.
    public var target: TitleRef? {
        focus == .inspector ? inspected ?? cursor?.ref : cursor?.ref ?? inspected
    }

    public func select(_ card: CardID) {
        cursor = card
        focus = .content
        if let (l, c) = navigator.position(of: card) { navigator.remembered[navigator.lines[l].key] = c }
    }

    public func move(_ move: Move) {
        guard let next = navigator.move(move, from: cursor) else { return }
        cursor = next
        // The inspector follows the keyboard, like the design.
        if inspected != nil, next.ref != inspected { open(next.ref, from: next, focusInside: false) }
    }

    // MARK: The inspector

    public var inspectorShown: Bool { inspected != nil }

    public func open(_ ref: TitleRef, from card: CardID? = nil, focusInside: Bool) {
        if inspected != ref {
            stopTrailer()
            inspected = ref
            detail = nil
            similar = []
            watchInfo = nil
            screenMenu = nil
            detailTask?.cancel()
            watchTask?.cancel()
            detailTask = Task { await loadDetail(ref) }
        }
        if let card { inspectorOrigin = card }
        focus = focusInside ? .inspector : .content
    }

    /// Space: shows or hides the details without moving focus.
    public func toggleInspector() {
        guard let cursor else { return }
        if inspected == cursor.ref { closeInspector(restoreFocus: false) } else { open(cursor.ref, from: cursor, focusInside: false) }
    }

    public func closeInspector(restoreFocus: Bool = true) {
        stopTrailer()
        detailTask?.cancel()
        watchTask?.cancel()
        inspected = nil
        detail = nil
        similar = []
        watchInfo = nil
        screenMenu = nil
        if restoreFocus, let origin = inspectorOrigin {
            cursor = navigator.position(of: origin) != nil ? origin : navigator.keep(origin, previous: navigator)
        }
        inspectorOrigin = nil
        focus = .content
    }

    public var detailTaskForTests: Task<Void, Never>? { detailTask }

    func loadDetail(_ ref: TitleRef) async {
        guard let api else { return }
        do {
            async let detailAnswer = api.title(ref, scope: scope)
            async let similarAnswer = api.similar(to: ref, scope: scope).items
            let (loaded, similar) = try await (detailAnswer, similarAnswer)
            guard inspected == ref else { return }
            detail = loaded
            self.similar = Array(similar.prefix(4))
            followProgress(of: loaded)
            followWatch(of: loaded)
        } catch is CancellationError {
        } catch {
            if inspected == ref { report(error) }
        }
    }

    /// After the details: where an available title can be watched. Asked
    /// apart, so a slow Jellyfin never holds the details back.
    private func followWatch(of detail: TitleDetail) {
        watchTask?.cancel()
        guard canWatch, let api, detail.availability == .available || detail.availability == .partiallyAvailable else { return }
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

    /// Esc: the menu, then the trailer, then the inspector, then the search.
    public func escape() {
        if reasonMenu != nil {
            reasonMenu = nil
        } else if player != nil {
            stopTrailer()
        } else if inspected != nil {
            closeInspector()
        } else if page == .search {
            query = ""
        }
    }

    // MARK: The trailer

    /// T, or the play button: opens the details and starts the trailer.
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

    /// K, or the buttons: starts an available title on the TV when one screen
    /// has Jellyfin open, opens it here when none has, and asks when several have.
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
            show(detail.availability == .available || detail.availability == .partiallyAvailable
                ? "Jellyfin heeft \(detail.title) niet gevonden."
                : "\(detail.title) staat nog niet in Jellyfin.")
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
            show(played.confirmed
                ? "\(what) speelt op \(played.screen.name)."
                : "\(what) is gestart op \(played.screen.name); de tv meldt nog niets.")
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
            lastChange = ChangeNote(kind: kind, ref: ref, scope: scope)
            show(label, canUndo: undoable)
            await reload()
        } catch {
            report(error)
        }
    }

    /// J: on the list of the scope you are in, or off it again. `seasons`
    /// picks which seasons of a series are asked for; none means the first.
    public func toggleList(_ ref: TitleRef? = nil, seasons: [Int]? = nil) async {
        guard let ref = ref ?? target, let title = summary(ref) else { return }
        let list = scope == .shared ? "onze lijst" : "jouw lijst"
        if title.onList {
            await perform("\(title.title) van \(list) gehaald.", .unlisted, ref) { try await $0.removeFromList(ref, scope: scope) }
        } else {
            let requests = status?.requests == true && title.availability == .notRequested
            let which = seasons.map { Self.seasonsLabel($0) }.map { " (\($0))" } ?? ""
            let label = requests ? "\(title.title) staat op \(list) en wordt zo aangevraagd\(which)." : "\(title.title) staat op \(list)\(which)."
            await perform(label, .listed, ref) { try await $0.addToList(ref, scope: scope, seasons: seasons) }
        }
    }

    /// "seizoen 1, 2" or "alle 4 seizoenen".
    public static func seasonsLabel(_ seasons: [Int], of total: Int? = nil) -> String {
        let sorted = seasons.sorted()
        if let total, total > 1, sorted == Array(1...total) { return "alle \(total) seizoenen" }
        return "seizoen " + sorted.map(String.init).joined(separator: ", ")
    }

    /// N with a reason or none; "Al gezien" is its own kind and no dislike.
    public func notNow(_ ref: TitleRef? = nil, reason: String? = nil) async {
        reasonMenu = nil
        guard let ref = ref ?? target, let title = summary(ref) else { return }
        let label = reason.map { "\(title.title) overgeslagen: \($0.lowercased())." } ?? "\(title.title) overgeslagen."
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
        await perform("\(title.title): al gezien.", .seen, ref) { try await $0.addVerdict(.seen, ref, scope: scope) }
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

    public var canUndo: Bool { !undoStack.isEmpty }

    /// Z or ⌘Z: the last change, exactly, and focus back where it was.
    public func undo() async {
        guard let entry = undoStack.popLast() else {
            show("Niets om ongedaan te maken.")
            return
        }
        guard let api else { return }
        do {
            _ = try await api.undo(change: entry.changeId)
            lastChange = ChangeNote(kind: .undone, ref: nil, scope: scope)
            show("Ongedaan gemaakt.")
            await reload()
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
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            if page == .search {
                page = pageBeforeSearch
                searchTask = Task { await reload() }
            }
            return
        }
        if page != .search {
            pageBeforeSearch = page
            page = .search
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    private func runSearch() async {
        guard let api else { return }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            loaded = []
            searchCredits = []
            return
        }
        do {
            let found = try await api.search(titles: text, scope: scope)
            guard text == query.trimmingCharacters(in: .whitespaces) else { return }
            let items = found.hits.map { hit -> TitleSummary in
                var title = hit.title
                title.match = hit.why
                return title
            }
            searchCredits = found.credits
            loaded = [TitleRow(
                key: "search", title: "Resultaten", subtitle: "\(items.count) voor ‘\(text)’", items: items,
                empty: "Geen resultaat voor ‘\(text)’. Probeer een kenmerk als Droge humor.", grid: true)]
        } catch {
            report(error, quiet: true)
        }
    }

    /// Return in the search field: to the first result.
    public func enterResults() {
        focus = .content
        cursor = navigator.first
    }

    // MARK: Toast

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
    public var cardWidth: Double { self == .wide ? 250 : 124 }
    public var cardStep: Double { cardWidth + 14 }
}
