import Foundation
import Observation

public enum SidebarItem: Hashable, Sendable {
    case inbox(mailboxId: String)
    /// Archief, Verstuurd or Spam of one mailbox.
    case folder(MailFolder, mailboxId: String)
    /// Concepten of one mailbox: drafts prepared by bots or agents, to review.
    case drafts(mailboxId: String)
    case tasks
    /// Evenementen: the household's outings.
    case outings

    /// The mailbox this place belongs to; the sidebar shows it under that mailbox.
    public var mailboxId: String? {
        switch self {
        case .inbox(let id), .folder(_, let id), .drafts(let id): id
        case .tasks, .outings: nil
        }
    }
}

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
        }
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
    public private(set) var searchExplanation: String?
    public private(set) var aiSearching = false
    /// Bumped by ⌘F; the window moves focus to the search field.
    public var searchFocusRequest = 0
    public var isSearching: Bool { !searchQuery.isEmpty }
    public internal(set) var messages: [MessageSummary] = []
    public var selectedMessageId: String? {
        didSet { if oldValue != selectedMessageId { messageLoad = Task { await openSelected() } } }
    }
    public private(set) var detail: MessageDetail?
    public private(set) var insights: MessageInsights?
    public private(set) var insightsLoading = false
    /// What the open mail says about an outing, and the outing it belongs to.
    public internal(set) var outingSuggestion: OutingSuggestion?
    public internal(set) var outing: Outing?
    public internal(set) var outingBusy = false
    /// The household's outings for the Evenementen page, every one of them.
    public internal(set) var outings: [Outing] = [] {
        didSet { if oldValue != outings { outingsChanged?() } }
    }
    public var selectedOutingId: String?
    /// Whether Details is open under an outing; kept while Hedwig runs.
    public var showsOutingDetails = false
    /// Tickets being uploaded right now.
    public internal(set) var ticketUploads = 0
    /// Outings whose picture is being changed right now.
    public internal(set) var pictureBusy: Set<String> = []
    @ObservationIgnored let pictureCache = OutingPictureCache()
    /// Everyone in the household, for Wie and the ticket holders.
    public internal(set) var people: [Person] = []
    /// Called whenever the outings change; the app reschedules its reminders.
    public var outingsChanged: (@MainActor () -> Void)?
    /// What the bot moved to Spam or Archief and the person has not reviewed yet.
    public private(set) var filtered: [FilteredEntry] = []
    public private(set) var drafts: [Draft] = []
    public var selectedDraftId: String?
    public private(set) var tasks: [TaskItem] = []
    public var selectedTaskId: String?
    /// The household's runners and the work waiting for this person.
    public private(set) var runners: RunnersResponse?
    /// The server's count per mailbox and folder, over all mail and not only the loaded page.
    public private(set) var folderCounts: [FolderCount] = []
    public private(set) var isLoading = false
    public var error: String?
    /// Whether the server answers; while it does not, loads retry quietly.
    public let reachability: ServerReachability
    /// Open compose windows; restarting would lose what is in them.
    public var composing = 0

    private let store: ConnectionStore
    private let makeClient: @Sendable (Connection) -> APIClient
    private var eventsTask: Task<Void, Never>?
    // The loads the two selections start, so a caller can wait for them.
    var selectionLoad: Task<Void, Never>?
    var messageLoad: Task<Void, Never>?
    var searchLoad: Task<Void, Never>?

    public init(
        store: ConnectionStore = ConnectionStore(app: "hedwig"),
        makeClient: @escaping @Sendable (Connection) -> APIClient = { APIClient(baseURL: $0.serverURL, token: $0.token) },
        connection: Connection? = nil,
        reachability: ServerReachability = ServerReachability()
    ) {
        self.store = store
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
        await refreshRunners()
        await refreshOutings()
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
        if event.type == "outing.changed" {
            await refreshOutings()
            if let id = event["outingId"], id == outing?.id || id == outingSuggestion?.outingId, let messageId = detail?.id {
                await loadOuting(messageId: messageId)
            }
        }
    }

    // MARK: Errors and the connection

    /// Shows an error in the alert. When the server cannot be reached and the
    /// call was a load (`quiet`), only the indicator in the sidebar changes:
    /// the load repeats once the server is back.
    func report(_ error: any Error, quiet: Bool = false) {
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
            await refreshOutings()
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
        do {
            switch selection {
            case .inbox(let id):
                messages = try await api.messages(mailboxId: id, folder: .inbox)
            case .folder(let folder, let id):
                let list = try await api.messages(mailboxId: id, folder: folder)
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
            case .outings:
                await refreshOutings()
                messages = []
            }
            if !keepSelection || !messages.contains(where: { $0.id == selectedMessageId }) {
                selectedMessageId = messages.first?.id
            }
        } catch {
            report(error, quiet: true)
        }
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
            // Spam stays unread until the person says it is not spam.
            if message.unread, message.folder != .spam, me?.can(.organize) == true {
                message = try await api.apply([.markRead], to: id)
                replace(message.summary)
                await refreshCounts()
            }
            if selectedMessageId == id {
                detail = message
                insights = nil
                outingSuggestion = nil
                outing = nil
                await loadOuting(messageId: id)
                // The bot only gets asked when it is likely to help: mail that
                // needs an answer, or long mail worth a summary.
                if message.flagged || (message.bodyText?.count ?? 0) > 1_500 { await loadInsights() }
            }
        } catch {
            report(error, quiet: true)
        }
    }

    /// Applies operations at the provider. A message that leaves the current
    /// list disappears and the next one is selected, like Apple Mail.
    public func perform(_ ops: [ServerOp], on id: String? = nil) async {
        guard let api, let id = id ?? selectedMessageId else { return }
        do {
            let updated = try await api.apply(ops, to: id)
            if stillBelongs(updated.summary) {
                replace(updated.summary)
                if detail?.id == id { detail = updated }
            } else {
                removeFromList(id)
            }
            await refreshCounts()
        } catch {
            report(error)
        }
    }

    public func toggleRead() async {
        guard let message = currentSummary else { return }
        await perform([message.unread ? .markRead : .markUnread])
    }

    public func toggleFlag() async {
        guard let message = currentSummary else { return }
        await perform([message.flagged ? .unflag : .flag])
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

    // MARK: Search

    private var searchQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    // The last search asked the bot, so a new place asks it again.
    private var searchedByMeaning = false

    /// The place in the sidebar as a search scope; nil for places without mail.
    public var placeScope: SearchScope? {
        switch selection {
        case .inbox(let id): SearchScope(mailboxId: id, folder: .inbox)
        case .folder(let folder, let id): SearchScope(mailboxId: id, folder: folder)
        case nil: .everywhere
        default: nil
        }
    }

    public var searchScope: SearchScope { searchEverywhere ? .everywhere : placeScope ?? .everywhere }

    private func rerunSearch() {
        searchLoad?.cancel()
        searchLoad = Task { searchedByMeaning ? await askBot() : await searchWords() }
    }

    /// Word search as you type, after a short pause; an empty field brings the list back.
    func searchWords() async {
        let query = searchQuery
        searchExplanation = nil
        aiSearching = false
        searchedByMeaning = false
        guard !query.isEmpty else {
            searchEverywhere = false
            await loadSelection(keepSelection: true)
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled, let api else { return }
        do {
            let scope = searchScope
            let response = try await api.search(query, in: scope, includeLow: searchIncludesLow)
            guard !Task.isCancelled, query == searchQuery, scope == searchScope else { return }
            showResults(response.results)
        } catch {
            if !Task.isCancelled { report(error, quiet: true) }
        }
    }

    /// Search by meaning (Enter in the search field): the bot plans the search on the server.
    public func searchWithAI() async {
        searchLoad?.cancel()
        await askBot()
    }

    private func askBot() async {
        let question = searchQuery
        guard !question.isEmpty, let api else { return }
        let scope = searchScope
        searchedByMeaning = true
        aiSearching = true
        defer { if question == searchQuery, scope == searchScope { aiSearching = false } }
        do {
            let response = try await api.aiSearch(question, in: scope, includeLow: searchIncludesLow)
            guard question == searchQuery, scope == searchScope else { return }
            searchExplanation = response.explanation
            showResults(response.results)
        } catch {
            if question == searchQuery, scope == searchScope { report(error) }
        }
    }

    private func showResults(_ results: [MessageSummary]) {
        messages = results
        if !results.contains(where: { $0.id == selectedMessageId }) { selectedMessageId = results.first?.id }
    }

    private func replace(_ message: MessageSummary) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
    }

    private func removeFromList(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages.remove(at: index)
        if selectedMessageId == id {
            selectedMessageId = messages.indices.contains(index) ? messages[index].id : messages.last?.id
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

    // MARK: Writing

    public func reply(all: Bool = false) -> ComposeDraft? {
        guard let message = detail, let me else { return nil }
        let own = Set(me.mailboxes.map { $0.address.lowercased() })
        var cc: [Address] = []
        if all {
            cc = (message.to + message.cc).filter { !own.contains($0.email.lowercased()) && $0.email != message.from.email }
        }
        return ComposeDraft(
            mailboxId: message.mailboxId,
            to: Address.format([message.from]),
            cc: Address.format(cc),
            subject: message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)",
            body: "\n\n" + quote(message),
            inReplyTo: message.id)
    }

    public func forward() -> ComposeDraft? {
        guard let message = detail else { return nil }
        return ComposeDraft(
            mailboxId: message.mailboxId,
            subject: message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)",
            body: "\n\n" + quote(message))
    }

    public func newMessage() -> ComposeDraft? {
        guard let box = currentMailboxId ?? me?.mailboxes.first?.id else { return nil }
        return ComposeDraft(mailboxId: box)
    }

    public var currentMailboxId: String? { selection?.mailboxId ?? detail?.mailboxId }

    public func compose(from draft: Draft) -> ComposeDraft {
        ComposeDraft(
            mailboxId: draft.mailboxId, to: Address.format(draft.to), cc: Address.format(draft.cc),
            subject: draft.subject, body: draft.body, inReplyTo: draft.inReplyTo, serverDraftId: draft.id)
    }

    public func send(_ draft: ComposeDraft) async throws {
        guard let api else { return }
        try await api.send(
            SendRequest(
                mailboxId: draft.mailboxId, to: Address.parseList(draft.to), cc: Address.parseList(draft.cc),
                subject: draft.subject, body: draft.body, inReplyTo: draft.inReplyTo))
        if let id = draft.serverDraftId {
            try? await api.deleteDraft(id)
            await refreshDrafts()
        }
    }

    public func discard(_ draft: Draft) async {
        guard let api else { return }
        try? await api.deleteDraft(draft.id)
        await refreshDrafts()
    }

    private func quote(_ message: MessageDetail) -> String {
        let date = message.receivedAt.formatted(date: .long, time: .shortened)
        let text = message.bodyText ?? message.snippet
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        return "Op \(date) schreef \(message.from.display):\n\(quoted)"
    }
}

extension AppModel {
    public func loadInsights() async {
        guard let api, let id = detail?.id else { return }
        insightsLoading = true
        defer { insightsLoading = false }
        if let result = try? await api.insights(messageId: id), detail?.id == id { insights = result }
    }

    public func compose(reply: MessageInsights.Reply) -> ComposeDraft? {
        guard var draft = self.reply() else { return nil }
        draft.body = reply.body + draft.body
        return draft
    }
}

// MARK: Tasks

extension AppModel {
    public func refreshTasks() async {
        guard let api else { return }
        await refreshRunners()
        if let list = try? await api.tasks() {
            tasks = list
            if selectedTaskId == nil || !list.contains(where: { $0.id == selectedTaskId }) {
                selectedTaskId = list.first(where: { $0.status == "review" })?.id ?? list.first?.id
            }
        }
    }

    public func approve(_ task: TaskItem) async {
        guard let api else { return }
        do {
            try await api.approve(task: task.id)
            await refreshTasks()
            await refreshDrafts()
        } catch {
            report(error)
        }
    }

    public func reject(_ task: TaskItem) async {
        guard let api else { return }
        do {
            try await api.reject(task: task.id)
            await refreshTasks()
        } catch {
            report(error)
        }
    }

    public var tasksAwaitingReview: Int { tasks.filter { $0.status == "review" }.count }

    public func refreshRunners() async {
        guard let api, me?.can(.read) == true else { return }
        runners = try? await api.runners()
    }

    /// The runners this person registered from this Mac (`burrowctl runner`).
    public var thisMacRunners: [RunnerInfo] {
        let name = RunnerConfig.load().name
        return runners?.runners.filter { $0.mine && $0.name == name } ?? []
    }

    /// What this Mac's runner is doing, for the task list.
    public var runnerStatus: String {
        guard let mine = thisMacRunners.first else { return "Geen runner op deze Mac" }
        if !mine.online { return "Runner offline" }
        if mine.paused { return "Runner gepauzeerd" }
        return mine.doing ?? "Runner wacht op taken"
    }

    public func setRunner(_ runner: RunnerInfo, paused: Bool) async {
        guard let api else { return }
        do {
            try await api.setRunner(id: runner.id, paused: paused)
            await refreshRunners()
        } catch {
            report(error)
        }
    }
}
