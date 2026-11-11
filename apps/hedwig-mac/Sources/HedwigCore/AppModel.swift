import BurrowKit
import Foundation
import Observation

/// The app's state and every action the views can take. Views stay dumb; this
/// is where the API is called, so it is what the tests exercise.
@MainActor
@Observable
public final class AppModel {
    public private(set) var connection: Connection?
    public private(set) var me: Me?
    public var selection: SidebarItem? {
        didSet {
            guard oldValue != selection else { return }
            if isSearching {
                // A search follows the sidebar to the next place with mail, like
                // Mail; the other places end it.
                guard placeScope != nil else {
                    searchText = ""
                    return
                }
                searchEverywhere = false
                rerunSearch()
                return
            }
            selectionLoad = Task { await loadSelection() }
        }
    }
    /// Searches the open place while not empty; the list then shows the results.
    public var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            searchLoad?.cancel()
            searchLoad = Task { await searchWords() }
            suggest()
        }
    }
    /// The chips in the search field: people, a period, kinds of mail.
    public var searchTokens: [SearchToken] = [] {
        didSet {
            guard oldValue != searchTokens else { return }
            // A chip picked from the suggestions takes the place of the words it stood for.
            if let added = searchTokens.first(where: { !oldValue.contains($0) }),
               let suggestion = searchSuggestions.first(where: { $0.token == added }) {
                let rest = suggestion.text(after: typedBeforeChip)
                Task { @MainActor in if self.searchText != rest { self.searchText = rest } }
            }
            searchSuggestions = []
            rerunSearch()
        }
    }
    /// What the field offers as chips for the words being typed.
    public internal(set) var searchSuggestions: [SearchSuggestion] = []
    /// The bot's plan as chips, after a search by meaning.
    public internal(set) var planTokens: [SearchToken] = []
    /// The bot's answer to the question, with the mail it rests on.
    public internal(set) var searchAnswer: SearchAnswer?
    /// The bot is reading the best results.
    public internal(set) var searchRanking = false
    /// Every match on the server, beyond the list.
    public internal(set) var searchTotal = 0
    /// The word search found no mail with every word and shows the closest.
    public internal(set) var searchLoose = false
    public var searchSort: SearchSort = .best {
        didSet { if oldValue != searchSort { sortResults() } }
    }
    /// Widens the search from the open place to every mailbox.
    public var searchEverywhere = false {
        didSet { if oldValue != searchEverywhere, isSearching { rerunSearch() } }
    }
    /// Also finds login codes and other low-priority mail, hidden by default.
    public var searchIncludesLow = false {
        didSet { if oldValue != searchIncludesLow, isSearching { rerunSearch() } }
    }
    /// What the bot searched for after an AI search.
    public internal(set) var searchExplanation: String?
    public internal(set) var aiSearching = false
    /// Bumped by ⌘F; the window moves focus to the search field.
    public var searchFocusRequest = 0
    public var isSearching: Bool { !searchQuery.isEmpty || !searchTokens.isEmpty }
    public internal(set) var messages: [MessageSummary] = []
    /// The open message: the selection when it is one message, nil for none or several.
    public var selectedMessageId: String? {
        didSet {
            guard oldValue != selectedMessageId else { return }
            if let id = selectedMessageId {
                if selectedMessageIds != [id] { selectedMessageIds = [id] }
            } else {
                if selectedMessageIds.count == 1 { selectedMessageIds = [] }
                detail = nil
            }
            messageLoad = Task { await openSelected() }
        }
    }
    /// The list's selection, as in Mail: several messages open none and act together.
    public var selectedMessageIds: Set<String> = [] {
        didSet {
            guard oldValue != selectedMessageIds else { return }
            // Read mail stays under "Ongelezen" until you move on, like Mail.
            let left = oldValue.subtracting(selectedMessageIds)
            if !left.isEmpty { messages.removeAll { left.contains($0.id) && !matchesFilter($0) } }
            let open = selectedMessageIds.count == 1 ? selectedMessageIds.first : nil
            if open != selectedMessageId { selectedMessageId = open }
        }
    }
    /// Mail's list filter: the criteria are remembered, the filter itself starts off.
    public var filterOn = false {
        didSet { if oldValue != filterOn { reloadForFilter() } }
    }
    public var filterCriteria: Set<ListFilter> = [.unread] {
        didSet {
            guard oldValue != filterCriteria else { return }
            ListFilter.save(filterCriteria, to: defaults)
            if filterOn { reloadForFilter() }
        }
    }
    public private(set) var detail: MessageDetail?
    public internal(set) var insights: MessageInsights?
    public internal(set) var insightsLoading = false
    /// Everyone in the household, to share mail with.
    public internal(set) var people: [Person] = []
    /// What the bot moved to Spam or Archief and the person has not reviewed yet.
    public private(set) var filtered: [FilteredEntry] = []
    /// Inbox mail the bot thought might be spam; it waits for the person.
    public private(set) var doubts: [FilteredEntry] = []
    public private(set) var drafts: [Draft] = []
    public var selectedDraftId: String?
    public internal(set) var tasks: [TaskItem] = []
    public var selectedTaskId: String?
    /// The household's runners and the work waiting for this person.
    public internal(set) var runners: RunnersResponse?
    /// The server's count per mailbox and folder, over all mail and not only the loaded page.
    public private(set) var folderCounts: [FolderCount] = []
    public private(set) var isLoading = false
    public var error: String?
    /// Whether the server answers; while it does not, loads retry quietly.
    public let reachability: ServerReachability
    /// Open compose windows; restarting would lose what is in them.
    public var composing = 0

    private let store: ConnectionStore
    @ObservationIgnored private let defaults: UserDefaults
    private let makeClient: @Sendable (Connection) -> APIClient
    private var eventsTask: Task<Void, Never>?
    // The loads the two selections start, so a caller can wait for them.
    var selectionLoad: Task<Void, Never>?
    var messageLoad: Task<Void, Never>?
    var searchLoad: Task<Void, Never>?
    var suggestionLoad: Task<Void, Never>?
    @ObservationIgnored var typedBeforeChip = ""
    // The results in the server's order, for sorting back to "best"; observed,
    // since the lenses are drawn from it.
    var bestResults: [MessageSummary] = []
    @ObservationIgnored var lastPlan: JSONValue?
    // The last search asked the bot, so a new place asks it again.
    var searchedByMeaning = false
    @ObservationIgnored var droppedPlanKeys: [String] = []
    /// Embeds the question on this Mac, when Ollama has the model; nil otherwise.
    @ObservationIgnored public var embedQuestion: @Sendable (String) async -> [Double]? = { question in
        try? await OllamaAgent().embed(["task: search result | query: \(question)"], model: "ollama:embeddinggemma", dims: 256).first
    }

    public init(
        store: ConnectionStore = ConnectionStore(app: "hedwig"),
        makeClient: @escaping @Sendable (Connection) -> APIClient = { APIClient(baseURL: $0.serverURL, token: $0.token) },
        connection: Connection? = nil,
        reachability: ServerReachability = ServerReachability(),
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.defaults = defaults
        filterCriteria = ListFilter.load(from: defaults)
        self.makeClient = makeClient
        self.reachability = reachability
        // HEDWIG_SERVER and HEDWIG_KEY connect without touching the Keychain,
        // for demos and automated screenshots.
        let env = ProcessInfo.processInfo.environment
        if connection == nil, let server = env["HEDWIG_SERVER"].flatMap(URL.init(string:)), let key = env["HEDWIG_KEY"] {
            self.connection = Connection(serverURL: server, token: key)
        } else {
            self.connection = connection ?? store.load()
        }
        reachability.probe = { [weak self] in await self?.serverAnswers() ?? false }
        reachability.onRegained = { [weak self] in await self?.reconnected() }
    }

    public var api: APIClient? { connection.map(makeClient) }

    // MARK: Connecting

    public func connect(serverURL: URL, token: String) async throws {
        let candidate = Connection(serverURL: serverURL, token: token)
        let me = try await makeClient(candidate).me()
        try store.save(candidate)
        connection = candidate
        self.me = me
        await start()
    }

    public func disconnect() {
        eventsTask?.cancel()
        store.clear()
        connection = nil
        me = nil
        messages = []
        detail = nil
        selection = nil
    }

    /// Loads who we are and the first screen, then follows live changes.
    public func start() async {
        guard let api else { return }
        do {
            me = try await api.me()
        } catch APIError.unauthorized {
            disconnect()
            error = APIError.unauthorized.errorDescription
            return
        } catch {
            report(error, quiet: true)
            return
        }
        if let id = selection?.mailboxId, mailbox(id) == nil { selection = nil }
        if selection == nil, let first = me?.mailboxes.first { selection = .inbox(mailboxId: first.id) }
        await refreshFiltered()
        if let place = ProcessInfo.processInfo.environment["HEDWIG_OPEN"] {
            if let box = me?.mailboxes.first(where: { $0.address == place }) {
                selection = .inbox(mailboxId: box.id)
            } else {
                try? select(place)
            }
        }
        await refreshCounts()
        await refreshDrafts()
        await refreshTasks()
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            let reachability = self?.reachability
            let connected: @Sendable (Bool) -> Void = { up in
                Task { @MainActor in up ? await reachability?.answered() : reachability?.lost() }
            }
            guard let stream = self?.api?.events(connected: connected) else { return }
            for await event in stream { await self?.handle(event) }
        }
    }

    func handle(_ event: ServerEvent) async {
        await refreshCounts()
        await refreshFiltered()
        if isSearching { return }
        if case .inbox(let id) = selection, event.mailboxId == id {
            await loadSelection(keepSelection: true)
        } else if case .folder(_, let id) = selection, event.mailboxId == id {
            await loadSelection(keepSelection: true)
        }
        if event.messageId == detail?.id, event.type == "message.changed" { await openSelected() }
        // A setting changed on another Mac: who we are again, so the language and the
        // features follow at once.
        if event.type == "settings.changed" || event.type == "mailbox.changed" { me = (try? await api?.me()) ?? me }
    }

    // MARK: Errors and the connection

    /// Shows an error in the alert. When the server cannot be reached and the
    /// call was a load (`quiet`), only the indicator in the sidebar changes:
    /// the load repeats once the server is back.
    func report(_ error: any Error, quiet: Bool = false) {
        // A request cancelled because the person typed on or picked another mail.
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        if APIError.isTransient(error) {
            reachability.lost()
            if quiet { return }
        }
        self.error = APIError.describe(error)
    }

    func serverAnswers() async -> Bool {
        guard let api else { return false }
        do {
            _ = try await api.me()
            return true
        } catch {
            return !APIError.isTransient(error)
        }
    }

    /// Catches up on what changed while the server was away.
    func reconnected() async {
        if me == nil {
            await start()
            guard me != nil else { return }
        } else {
            await refreshCounts()
            await refreshFiltered()
            await refreshDrafts()
            await refreshTasks()
        }
        if !isSearching { await loadSelection(keepSelection: true) }
        if selectedMessageId != detail?.id { await openSelected() }
    }

    // MARK: Lists

    public func mailbox(_ id: String) -> MailboxSummary? { me?.mailboxes.first { $0.id == id } }

    public struct MailboxGroup: Identifiable, Sendable {
        public let role: MailboxRole
        public let mailboxes: [MailboxSummary]
        public var id: MailboxRole { role }
    }

    /// The key's mailboxes by role, private first, in the server's order within a role.
    public var mailboxGroups: [MailboxGroup] {
        MailboxRole.allCases.compactMap { role in
            let boxes = (me?.mailboxes ?? []).filter { $0.kind == role }
            return boxes.isEmpty ? nil : MailboxGroup(role: role, mailboxes: boxes)
        }
    }

    public func updateMailbox(_ id: String, name: String? = nil, role: MailboxRole? = nil, instructions: String? = nil) async throws {
        guard let api else { return }
        let updated = try await api.updateMailbox(id: id, name: name, role: role, instructions: instructions)
        if let index = me?.mailboxes.firstIndex(where: { $0.id == id }) { me?.mailboxes[index] = updated }
    }

    /// Moves mailboxes within their role, as dragged in the sidebar, and saves the order.
    public func moveMailboxes(in role: MailboxRole, from source: IndexSet, to destination: Int) async {
        guard let api, let all = me?.mailboxes else { return }
        let group = all.filter { $0.kind == role }
        var rest = group.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: source.map { group[$0] }, at: destination - source.filter { $0 < destination }.count)
        let ordered = MailboxRole.allCases.flatMap { r in r == role ? rest : all.filter { $0.kind == r } }
        me?.mailboxes = ordered
        do {
            try await api.orderMailboxes(ordered.map(\.id))
        } catch {
            me?.mailboxes = all
            report(error)
        }
    }

    public func setLanguage(_ language: String?) async throws {
        guard let api else { return }
        let trimmed = language?.trimmingCharacters(in: .whitespaces)
        let value = trimmed?.isEmpty == false ? trimmed : nil
        try await api.setLanguage(value)
        me?.language = value
    }

    public func loadSelection(keepSelection: Bool = false) async {
        guard let api, let selection else { return }
        isLoading = true
        defer { isLoading = false }
        let shown = messages
        let filter = serverFilter
        do {
            switch selection {
            case .inbox(let id):
                messages = try await api.messages(mailboxId: id, folder: .inbox, filter: filter?.criteria ?? [], since: filter?.since)
            case .folder(let folder, let id):
                let list = try await api.messages(mailboxId: id, folder: folder, filter: filter?.criteria ?? [], since: filter?.since)
                if folder == .spam || folder == .archive {
                    await refreshFiltered()
                    messages = reviewFirst(list)
                } else {
                    messages = list
                }
            case .drafts(let id):
                await refreshDrafts()
                messages = []
                let here = drafts(in: id)
                if !here.contains(where: { $0.id == selectedDraftId }) { selectedDraftId = here.first?.id }
            case .tasks:
                await refreshTasks()
                messages = []
            case .shared:
                messages = try await sharedMessages()
            }
            if keepSelection, filter != nil { keepSelectedMessages(from: shown) }
            keepSelection ? keepOnlyListedSelection() : selectFirst()
        } catch {
            report(error, quiet: true)
        }
    }

    /// Selected mail stays in a filtered list after it stopped matching, at its old place.
    private func keepSelectedMessages(from shown: [MessageSummary]) {
        for (index, message) in shown.enumerated()
        where selectedMessageIds.contains(message.id) && !messages.contains(where: { $0.id == message.id }) && stillBelongs(message) {
            messages.insert(message, at: min(index, messages.count))
        }
    }

    private func selectFirst() {
        selectedMessageIds = messages.first.map { [$0.id] } ?? []
    }

    /// Drops selected mail the list no longer holds; with none left, the first is selected.
    func keepOnlyListedSelection() {
        let listed = selectedMessageIds.filter { id in messages.contains { $0.id == id } }
        if listed.isEmpty { selectFirst() } else if listed != selectedMessageIds { selectedMessageIds = listed }
    }

    private func reloadForFilter() {
        guard !isSearching, selection != nil else { return }
        selectionLoad = Task { await loadSelection(keepSelection: true) }
    }

    public func refresh() async {
        guard let api else { return }
        for box in me?.mailboxes ?? [] { try? await api.sync(mailboxId: box.id) }
        await loadSelection(keepSelection: true)
        await refreshCounts()
    }

    func refreshCounts() async {
        guard let api, let counts = try? await api.counts() else { return }
        folderCounts = counts
    }

    public func count(mailboxId: String, folder: MailFolder) -> FolderCount? {
        folderCounts.first { $0.mailboxId == mailboxId && $0.folder == folder }
    }

    /// Unread inbox mail per mailbox, for the sidebar.
    public var unreadCounts: [String: Int] {
        Dictionary(folderCounts.filter { $0.folder == .inbox }.map { ($0.mailboxId, $0.unread) }, uniquingKeysWith: +)
    }

    /// The open folder's size for the list header: the server's count, or the loaded list without one.
    public var placeCount: (total: Int, unread: Int) {
        let counted: FolderCount? = switch selection {
        case .inbox(let id): count(mailboxId: id, folder: .inbox)
        case .folder(let folder, let id): count(mailboxId: id, folder: folder)
        default: nil
        }
        if let counted, !isSearching { return (counted.total, counted.unread) }
        return (messages.count, messages.filter(\.unread).count)
    }

    func refreshFiltered() async {
        guard let api else { return }
        if let list = try? await api.filtered() { filtered = list }
        if let list = try? await api.doubts() { doubts = list }
    }

    public func doubt(for messageId: String) -> FilteredEntry? {
        doubts.first { $0.message.id == messageId }
    }

    /// Spam and doubt cases load remote images only when the person asks for
    /// that one message; other mail also by the "Altijd" setting.
    public func loadsRemoteImagesUnasked(_ message: MessageDetail) -> Bool {
        message.mayLoadRemoteImages && doubt(for: message.id) == nil
    }

    /// The bot's choice about this message, while it waits for review.
    public func review(for messageId: String) -> FilteredEntry? {
        filtered.first { $0.message.id == messageId }
    }

    /// The bot's choices still to review in one folder of a mailbox.
    public func reviews(in folder: MailFolder, mailboxId: String) -> [FilteredEntry] {
        filtered.filter { $0.message.mailboxId == mailboxId && $0.message.folder == folder }
    }

    public func drafts(in mailboxId: String) -> [Draft] {
        drafts.filter { $0.mailboxId == mailboxId }
    }

    // The server lists reviews unsure first; the rest of the folder follows newest first.
    private func reviewFirst(_ list: [MessageSummary]) -> [MessageSummary] {
        let rank = Dictionary(filtered.enumerated().map { ($1.message.id, $0) }, uniquingKeysWith: min)
        return list.enumerated().sorted { a, b in
            let (ra, rb) = (rank[a.element.id] ?? Int.max, rank[b.element.id] ?? Int.max)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    func refreshDrafts() async {
        guard let api else { return }
        if let list = try? await api.drafts() { drafts = list }
    }

    // MARK: One message

    func openSelected() async {
        guard let api, let id = selectedMessageId else {
            detail = nil
            return
        }
        do {
            var message = try await api.message(id: id)
            // Spam stays unread until the person says it is not spam. A failed
            // mark still opens the message: it is already on the server.
            if message.unread, message.folder != .spam, message.share?.by == nil, me?.can(.organize) == true {
                do {
                    message = try await api.apply([.markRead], to: id)
                    replace(message.summary)
                    await refreshCounts()
                } catch {
                    await reportProviderError(error, mailboxId: message.mailboxId)
                }
            }
            if selectedMessageId == id {
                detail = message
                insights = nil
                // The bot only gets asked when it is likely to help: mail that
                // needs an answer, or long mail worth a summary.
                if message.flagged || (message.bodyText?.count ?? 0) > 1_500 { await loadInsights() }
            }
        } catch {
            report(error, quiet: true)
        }
    }

    /// Applies operations at the provider, to one message or else the whole
    /// selection. A message that leaves the current list disappears and the
    /// next one is selected, like Apple Mail.
    public func perform(_ ops: [ServerOp], on id: String? = nil) async {
        await perform(ops, on: id.map { [$0] } ?? selectedIds)
    }

    /// The server takes one message per call, so a selection is a call each; the
    /// first failure stops the rest.
    public func perform(_ ops: [ServerOp], on ids: [String]) async {
        await perform(ids.map { ($0, ops) })
    }

    private func perform(_ work: [(id: String, ops: [ServerOp])]) async {
        guard let api, !work.isEmpty else { return }
        var gone: [String] = []
        for (id, ops) in work {
            do {
                let updated = try await api.apply(ops, to: id)
                if stillBelongs(updated.summary) {
                    replace(updated.summary)
                    if detail?.id == id { detail = updated }
                } else {
                    gone.append(id)
                }
            } catch {
                removeFromList(gone)
                await reportProviderError(error, mailboxId: messages.first { $0.id == id }?.mailboxId ?? detail?.mailboxId)
                await refreshCounts()
                return
            }
        }
        removeFromList(gone)
        await refreshCounts()
        // Moving into or out of spam settles the bot's open verdicts on the server.
        if work.contains(where: { $0.ops.contains(.moveToSpam) || $0.ops.contains(.moveToInbox) }) {
            await refreshFiltered()
        }
    }

    /// The selection in list order; the open message when the list lost it.
    public var selectedIds: [String] {
        let listed = messages.map(\.id).filter(selectedMessageIds.contains)
        if listed.isEmpty, let id = selectedMessageId ?? detail?.id { return [id] }
        return listed
    }

    public func summaries(_ ids: [String]) -> [MessageSummary] {
        ids.compactMap { id in messages.first { $0.id == id } ?? (detail?.id == id ? detail?.summary : nil) }
    }

    /// Whether the menus may archive, delete, mark or move these (the selection by default).
    public func canOrganize(_ ids: [String]? = nil) -> Bool {
        let list = summaries(ids ?? selectedIds)
        return me?.can(.organize) == true && !list.isEmpty && list.allSatisfy { $0.share?.by == nil }
    }

    public var canOrganizeSelection: Bool { canOrganize() }

    /// Reply and forward need exactly one message of this person's own.
    public var canReply: Bool { detail != nil && detailIsMine && me?.can(.send) == true }

    /// A mailbox whose login the provider refused gets the notice to log in
    /// again instead of an alert; anything else is an alert as before.
    private func reportProviderError(_ error: any Error, mailboxId: String?) async {
        if case .server(status: 409, _) = error as? APIError, let mailboxId {
            me = (try? await api?.me()) ?? me
            if mailbox(mailboxId)?.needsReconnect == true { return }
        }
        report(error)
    }

    /// Mailboxes of this person whose login the provider refused.
    public var mailboxesToReconnect: [MailboxSummary] {
        (me?.mailboxes ?? []).filter { $0.needsReconnect == true && $0.ownerId == me?.person.id }
    }

    /// The provider's login for the browser; the server tells the app when it
    /// is done, and the notice goes away.
    public func reconnectLink(_ mailbox: MailboxSummary) async -> URL? {
        do {
            return try await api?.reconnectLink(mailboxId: mailbox.id)
        } catch {
            report(error)
            return nil
        }
    }

    /// Like Mail: read when any of them is unread, otherwise unread.
    public func toggleRead(_ ids: [String]? = nil) async {
        let list = summaries(ids ?? selectedIds)
        guard !list.isEmpty else { return }
        await perform([list.contains(where: \.unread) ? .markRead : .markUnread], on: list.map(\.id))
    }

    public func toggleFlag(_ ids: [String]? = nil) async {
        let list = summaries(ids ?? selectedIds)
        guard !list.isEmpty else { return }
        await perform([list.allSatisfy(\.flagged) ? .unflag : .flag], on: list.map(\.id))
    }

    /// What moves a message to a folder of its own mailbox; nil where it already is
    /// or the provider has no such move.
    private func moveOps(_ message: MessageSummary, to folder: MailFolder) -> [ServerOp]? {
        guard message.folder != folder else { return nil }
        return switch folder {
        // Out of spam the mail is read, as with "Geen spam".
        case .inbox: message.folder == .spam ? [.moveToInbox, .markRead] : [.moveToInbox]
        case .archive: [.archive]
        case .spam: [.moveToSpam]
        case .trash: [.trash]
        case .sent: nil
        }
    }

    private func target(_ place: SidebarItem) -> (folder: MailFolder, mailboxId: String)? {
        switch place {
        case .inbox(let id): (.inbox, id)
        case .folder(let folder, let id): (folder, id)
        default: nil
        }
    }

    /// A drop on a sidebar place: mail moves only between folders of its own mailbox.
    public func canMove(_ ids: [String], to place: SidebarItem) -> Bool {
        guard let target = target(place), canOrganize(ids) else { return false }
        let list = summaries(ids)
        return list.count == ids.count && list.allSatisfy { $0.mailboxId == target.mailboxId && moveOps($0, to: target.folder) != nil }
    }

    public func move(_ ids: [String], to place: SidebarItem) async {
        guard canMove(ids, to: place), let target = target(place) else { return }
        await move(ids, to: target.folder)
    }

    /// Moves each message to that folder of its own mailbox (Verplaats naar).
    public func move(_ ids: [String], to folder: MailFolder) async {
        let list = summaries(ids)
        var work: [(id: String, ops: [ServerOp])] = []
        for message in list {
            // The bot's spam waits for review; restoring it also teaches a rule.
            if folder == .inbox, message.folder == .spam, let entry = review(for: message.id) {
                await restore(entry)
            } else if let ops = moveOps(message, to: folder) {
                work.append((message.id, ops))
            }
        }
        await perform(work)
    }

    public func canMove(_ ids: [String], to folder: MailFolder) -> Bool {
        canOrganize(ids) && summaries(ids).contains { moveOps($0, to: folder) != nil }
    }

    public var currentSummary: MessageSummary? {
        messages.first { $0.id == selectedMessageId } ?? detail?.summary
    }

    private func stillBelongs(_ message: MessageSummary) -> Bool {
        if isSearching { return true }
        return switch selection {
        case .inbox(let id): message.mailboxId == id && message.folder == .inbox
        case .folder(let folder, let id): message.mailboxId == id && message.folder == folder
        default: true
        }
    }

    private func replace(_ message: MessageSummary) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
    }

    private func removeFromList(_ id: String) { removeFromList([id]) }

    /// With the selection gone, the message after it is selected, as in Mail.
    private func removeFromList(_ ids: [String]) {
        let gone = Set(ids)
        guard let first = messages.firstIndex(where: { gone.contains($0.id) }) else { return }
        let rest = messages.filter { !gone.contains($0.id) }
        let after = messages[first...].first { !gone.contains($0.id) && !selectedMessageIds.contains($0.id) }
        messages = rest
        let kept = selectedMessageIds.subtracting(gone)
        if !kept.isEmpty {
            selectedMessageIds = kept
        } else if !selectedMessageIds.isDisjoint(with: gone) || selectedMessageId.map(gone.contains) == true {
            let next = after ?? rest.last
            selectedMessageIds = next.map { [$0.id] } ?? []
        }
    }

    // MARK: Filtered review

    public func confirm(_ entry: FilteredEntry) async {
        await review { try await $0.confirm([entry.id]) }
    }

    /// Back to the inbox (read, for spam) and a learned rule for the sender.
    public func restore(_ entry: FilteredEntry) async {
        await review { try await $0.restore(entry.id) }
        removeFromList(entry.message.id)
    }

    /// The person's answer to a doubt; either way the server learns the sender.
    public func settle(_ entry: FilteredEntry, spam: Bool) async {
        await review { try await $0.settleDoubt(entry.id, spam: spam) }
        if spam, case .inbox = selection { removeFromList(entry.message.id) }
    }

    /// Confirms every review in the open Spam or Archief.
    public func confirmReviews() async {
        guard case .folder(let folder, let id) = selection else { return }
        let ids = reviews(in: folder, mailboxId: id).map(\.id)
        guard !ids.isEmpty else { return }
        await review { try await $0.confirm(ids) }
    }

    /// "Geen spam" for the open message: the bot's entry when it has one,
    /// otherwise straight back to the inbox. Only now is it read.
    public func notSpam() async {
        guard let message = currentSummary, message.folder == .spam else { return }
        if let entry = review(for: message.id) {
            await restore(entry)
        } else {
            await perform([.moveToInbox, .markRead], on: message.id)
        }
    }

    private func review(_ action: (APIClient) async throws -> Void) async {
        guard let api else { return }
        do {
            try await action(api)
            await refreshFiltered()
            await refreshCounts()
        } catch {
            report(error)
        }
    }
}
