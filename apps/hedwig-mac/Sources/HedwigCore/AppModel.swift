import Foundation
import Observation

public enum SidebarItem: Hashable, Sendable {
    case inbox(mailboxId: String)
    case filtered
    case drafts
    case folder(MailFolder)
}

/// The app's state and every action the views can take. Views stay dumb; this
/// is where the API is called, so it is what the tests exercise.
@MainActor
@Observable
public final class AppModel {
    public private(set) var connection: Connection?
    public private(set) var me: Me?
    public var selection: SidebarItem? {
        didSet { if oldValue != selection { Task { await loadSelection() } } }
    }
    public private(set) var messages: [MessageSummary] = []
    public var selectedMessageId: String? {
        didSet { if oldValue != selectedMessageId { Task { await openSelected() } } }
    }
    public private(set) var detail: MessageDetail?
    public private(set) var filtered: [FilteredEntry] = []
    public var selectedFilteredId: String?
    public private(set) var drafts: [Draft] = []
    public private(set) var unreadCounts: [String: Int] = [:]
    public private(set) var isLoading = false
    public var error: String?

    private let store: ConnectionStore
    private let makeClient: @Sendable (Connection) -> APIClient
    private var eventsTask: Task<Void, Never>?

    public init(
        store: ConnectionStore = ConnectionStore(),
        makeClient: @escaping @Sendable (Connection) -> APIClient = { APIClient(baseURL: $0.serverURL, token: $0.token) },
        connection: Connection? = nil
    ) {
        self.store = store
        self.makeClient = makeClient
        // HEDWIG_SERVER and HEDWIG_KEY connect without touching the Keychain,
        // for demos and automated screenshots.
        let env = ProcessInfo.processInfo.environment
        if connection == nil, let server = env["HEDWIG_SERVER"].flatMap(URL.init(string:)), let key = env["HEDWIG_KEY"] {
            self.connection = Connection(serverURL: server, token: key)
        } else {
            self.connection = connection ?? store.load()
        }
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
            self.error = error.localizedDescription
            return
        }
        if selection == nil, let first = me?.mailboxes.first { selection = .inbox(mailboxId: first.id) }
        switch ProcessInfo.processInfo.environment["HEDWIG_OPEN"] {
        case "filtered": selection = .filtered
        case "drafts": selection = .drafts
        case "archive": selection = .folder(.archive)
        default: break
        }
        await refreshCounts()
        await refreshFiltered()
        await refreshDrafts()
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            guard let stream = self?.api?.events() else { return }
            for await event in stream { await self?.handle(event) }
        }
    }

    func handle(_ event: ServerEvent) async {
        await refreshCounts()
        await refreshFiltered()
        if case .inbox(let id) = selection, event.mailboxId == id {
            await loadSelection(keepSelection: true)
        } else if case .folder = selection {
            await loadSelection(keepSelection: true)
        }
        if event.messageId == detail?.id, event.type == "message.changed" { await openSelected() }
    }

    // MARK: Lists

    public func mailbox(_ id: String) -> MailboxSummary? { me?.mailboxes.first { $0.id == id } }

    public func loadSelection(keepSelection: Bool = false) async {
        guard let api, let selection else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            switch selection {
            case .inbox(let id):
                messages = try await api.messages(mailboxId: id, folder: .inbox)
            case .folder(let folder):
                // "Overal" folders combine every mailbox, newest first.
                var all: [MessageSummary] = []
                for box in me?.mailboxes ?? [] {
                    all += try await api.messages(mailboxId: box.id, folder: folder, limit: 50)
                }
                messages = all.sorted { $0.receivedAt > $1.receivedAt }
            case .filtered:
                await refreshFiltered()
                messages = []
            case .drafts:
                await refreshDrafts()
                messages = []
            }
            if !keepSelection || !messages.contains(where: { $0.id == selectedMessageId }) {
                selectedMessageId = messages.first?.id
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func refresh() async {
        guard let api else { return }
        for box in me?.mailboxes ?? [] { try? await api.sync(mailboxId: box.id) }
        await loadSelection(keepSelection: true)
        await refreshCounts()
    }

    func refreshCounts() async {
        guard let api else { return }
        var counts: [String: Int] = [:]
        for box in me?.mailboxes ?? [] {
            let inbox = (try? await api.messages(mailboxId: box.id, folder: .inbox)) ?? []
            counts[box.id] = inbox.filter(\.unread).count
        }
        unreadCounts = counts
    }

    func refreshFiltered() async {
        guard let api else { return }
        if let list = try? await api.filtered() {
            filtered = list
            if selectedFilteredId == nil || !list.contains(where: { $0.id == selectedFilteredId }) {
                selectedFilteredId = list.first?.id
            }
        }
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
            if message.unread, me?.can(.organize) == true {
                message = try await api.apply([.markRead], to: id)
                replace(message.summary)
            }
            if selectedMessageId == id { detail = message }
        } catch {
            self.error = error.localizedDescription
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
            self.error = error.localizedDescription
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
        switch selection {
        case .inbox(let id): message.mailboxId == id && message.folder == .inbox
        case .folder(let folder): message.folder == folder
        default: true
        }
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

    public func restore(_ entry: FilteredEntry) async {
        await review { try await $0.restore(entry.id) }
    }

    public func confirmAll() async {
        await review { try await $0.confirmAll() }
    }

    private func review(_ action: (APIClient) async throws -> Void) async {
        guard let api else { return }
        let index = filtered.firstIndex { $0.id == selectedFilteredId }
        do {
            try await action(api)
            await refreshFiltered()
            if let index, !filtered.isEmpty {
                selectedFilteredId = filtered[min(index, filtered.count - 1)].id
            }
            await refreshCounts()
        } catch {
            self.error = error.localizedDescription
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

    public var currentMailboxId: String? {
        if case .inbox(let id) = selection { return id }
        return detail?.mailboxId
    }

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
