import Foundation
import Observation

/// Pensieve's state and every action its views take. Recording itself lives
/// in the app (it needs the microphone); what happens to a finished file is
/// here, so the tests can exercise it.
@MainActor
@Observable
public final class PensieveModel {
    public private(set) var connection: Connection?
    public private(set) var profile: Profile?
    public private(set) var people: [Person] = []
    public private(set) var recordings: [RecordingSummary] = []
    public var scope: RecordingScope = .all {
        didSet { if oldValue != scope { Task { await reload() } } }
    }
    public var query = ""
    public var selectedId: String? {
        didSet { if oldValue != selectedId { detailLoad = Task { await loadDetail() } } }
    }
    public private(set) var detail: RecordingDetail?
    public private(set) var pending: [PendingUpload] = []
    public private(set) var uploadProgress: [String: Double] = [:]
    public private(set) var lastMirror: Date?
    public var error: String?
    /// Set by the app while it records, for the sidebar and the agent state.
    public var recordingTitle: String?

    private let store: ConnectionStore
    private let makeClient: @Sendable (Connection) -> APIClient
    public let outbox: Outbox
    public let mirror: Mirror
    private var eventsTask: Task<Void, Never>?
    private var sending = false
    public private(set) var detailLoad: Task<Void, Never>?

    public init(
        store: ConnectionStore = ConnectionStore(app: "pensieve"),
        makeClient: @escaping @Sendable (Connection) -> APIClient = { APIClient(baseURL: $0.serverURL, token: $0.token) },
        connection: Connection? = nil, outbox: Outbox = Outbox(), mirror: Mirror = Mirror()
    ) {
        self.store = store
        self.makeClient = makeClient
        self.outbox = outbox
        self.mirror = mirror
        // PENSIEVE_SERVER and PENSIEVE_KEY connect without the Keychain, for
        // demos and automated runs against a test server.
        let environment = ProcessInfo.processInfo.environment
        if connection == nil, let server = environment["PENSIEVE_SERVER"].flatMap(URL.init(string:)),
           let key = environment["PENSIEVE_KEY"] {
            self.connection = Connection(serverURL: server, token: key)
        } else {
            self.connection = connection ?? store.load()
        }
        pending = outbox.all()
    }

    public var api: APIClient? { connection.map(makeClient) }

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
        recordings = []
        detail = nil
        selectedId = nil
    }

    /// Loads everything, sends what waits in the outbox, and follows changes.
    public func start() async {
        guard let api else { return }
        do {
            profile = try await api.profile()
        } catch APIError.unauthorized {
            logout()
            error = APIError.unauthorized.errorDescription
            return
        } catch {
            self.error = error.localizedDescription
            return
        }
        people = (try? await api.people()) ?? []
        await reload()
        Task { await sendPending() }
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            guard let stream = self?.api?.events() else { return }
            for await event in stream where event.type.hasPrefix("recording.") {
                await self?.handle(event)
            }
        }
    }

    func handle(_ event: ServerEvent) async {
        await reload()
        if event["recordingId"] == selectedId { await loadDetail() }
        if event["status"] == RecordingStatus.done.rawValue { await mirrorNow() }
    }

    public var mirrorEnabled: Bool { profile?.settings?["pensieve.mirror"]?.bool ?? true }

    // MARK: Lists

    public func reload() async {
        guard let api else { return }
        do {
            recordings = try await api.recordings(scope: scope, query: query.isEmpty ? nil : query)
            if selectedId == nil || !recordings.contains(where: { $0.id == selectedId }) {
                selectedId = recordings.first?.id
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadDetail() async {
        guard let api, let id = selectedId else {
            detail = nil
            return
        }
        if let loaded = try? await api.recording(id), selectedId == id { detail = loaded }
    }

    public var selected: RecordingSummary? { recordings.first { $0.id == selectedId } }

    // MARK: A finished recording

    /// Puts a finished file in the outbox and sends it; on failure it waits
    /// there for the next try.
    public func finished(audio: URL, title: String, startedAt: Date) async {
        let upload = PendingUpload(title: title, startedAt: startedAt, audio: audio.lastPathComponent)
        do {
            try outbox.add(upload)
        } catch {
            self.error = "De opname kon niet in de wachtrij: \(error.localizedDescription)"
        }
        pending = outbox.all()
        await sendPending()
    }

    /// Sends every pending upload, oldest first. Stops at the first failure;
    /// the rest waits for the next try.
    public func sendPending() async {
        guard let api, !sending else { return }
        sending = true
        defer { sending = false }
        for upload in outbox.all() {
            do {
                let id = upload.id
                let created = try await outbox.send(upload, api: api) { fraction in
                    Task { @MainActor [weak self] in self?.uploadProgress[id] = fraction }
                }
                uploadProgress[upload.id] = nil
                if let slug = upload.importedFrom { markImported(slug) }
                pending = outbox.all()
                await reload()
                if upload.source == "recorded" { selectedId = created.id }
            } catch {
                uploadProgress[upload.id] = nil
                pending = outbox.all()
                self.error = "Uploaden lukt nu niet; Pensieve probeert het later opnieuw. (\(error.localizedDescription))"
                return
            }
        }
    }

    // MARK: Changing a recording

    public func rename(_ id: String, to title: String) async {
        await act { try await $0.renameRecording(id, title: title) }
    }

    public func share(_ id: String, with personId: String) async {
        await act { try await $0.share(recording: id, with: personId) }
    }

    public func unshare(_ id: String, from personId: String) async {
        await act { try await $0.unshare(recording: id, from: personId) }
    }

    public func redo(_ id: String, step: String) async {
        await act { try await $0.redo(recording: id, step: step) }
    }

    public func delete(_ id: String) async {
        guard let api else { return }
        do {
            try await api.deleteRecording(id)
            if selectedId == id { selectedId = nil }
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func act(_ change: (APIClient) async throws -> RecordingSummary) async {
        guard let api else { return }
        do {
            _ = try await change(api)
            await reload()
            await loadDetail()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The other people of the household, for the share menu.
    public var others: [Person] { people.filter { $0.id != profile?.person.id } }

    // MARK: iCloud and RecHoarder

    public func mirrorNow() async {
        guard mirrorEnabled, let api else { return }
        do {
            let all = try await api.recordings(scope: .all)
            try await mirror.sync(all, api: api)
            lastMirror = Date()
        } catch {
            self.error = "De kopie in iCloud Drive lukte niet: \(error.localizedDescription)"
        }
    }

    static let importedKey = "app.burrow.pensieve.imported"

    public var importedFolders: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.importedKey) ?? [])
    }

    private func markImported(_ slug: String) {
        UserDefaults.standard.set(Array(importedFolders.union([slug])).sorted(), forKey: Self.importedKey)
    }

    /// Queues every RecHoarder meeting not imported before and sends them.
    /// Returns how many were queued and how many wait for iCloud.
    @discardableResult
    public func importRecHoarder(from source: RecHoarderImport = RecHoarderImport()) async -> (queued: Int, waiting: Int) {
        let queuedAlready = Set(outbox.all().compactMap(\.importedFrom))
        let scan = source.scan(skipping: importedFolders.union(queuedAlready))
        for upload in scan.ready { try? outbox.add(upload) }
        pending = outbox.all()
        await sendPending()
        return (scan.ready.count, scan.downloading.count)
    }
}
