import Foundation
import Observation
import PensieveMedia

/// Pensieve's state and every action its views take. Recording itself lives
/// in the app (it needs the microphone); what happens to a finished file is
/// here, so the tests can exercise it.
@MainActor
@Observable
public final class PensieveModel {
    public private(set) var connection: Connection?
    public private(set) var profile: Profile?
    public private(set) var people: [Person] = []
    /// Every kind, so the sidebar can count them; `recordings` is what the list shows.
    public private(set) var all: [RecordingSummary] = []
    public var scope: RecordingScope = .all {
        didSet { if oldValue != scope { Task { await reload() } } }
    }
    public var query = ""
    /// Only this kind; nil shows every kind.
    public var kindFilter: RecordingKind? {
        didSet { if oldValue != kindFilter { keepSelection() } }
    }
    /// Only recordings with any of these labels.
    public var labelFilter: Set<String> = [] {
        didSet { if oldValue != labelFilter { Task { await reload() } } }
    }
    /// The person's own labels, with how many recordings carry each.
    public private(set) var labels: [RecordingLabel] = []
    public var selectedId: String? {
        didSet { if oldValue != selectedId { detailLoad = Task { await loadDetail() } } }
    }
    public private(set) var detail: RecordingDetail?
    public private(set) var pending: [PendingUpload] = []
    public private(set) var uploadProgress: [String: Double] = [:]
    public private(set) var lastMirror: Date?
    public var error: String?
    /// Whether the server answers; while it does not, loads and uploads retry quietly.
    public let reachability: ServerReachability
    /// Set by the app while it records, for the sidebar and the agent state.
    public var recordingTitle: String?

    private let store: ConnectionStore
    private let makeClient: @Sendable (Connection) -> APIClient
    public let outbox: Outbox
    public let mirror: Mirror
    public let shelf: Shelf
    let encoder: VideoEncoder
    let probe: MediaProbing
    let extractAudio: @Sendable (URL, URL) async throws -> Void
    private var compression: Task<Void, Never>?
    private var compressAgain = false
    private var eventsTask: Task<Void, Never>?
    private var sending = false
    public private(set) var detailLoad: Task<Void, Never>?

    public init(
        store: ConnectionStore = ConnectionStore(app: "pensieve"),
        makeClient: @escaping @Sendable (Connection) -> APIClient = { APIClient(baseURL: $0.serverURL, token: $0.token) },
        connection: Connection? = nil, outbox: Outbox = Outbox(), mirror: Mirror = Mirror(),
        shelf: Shelf = Shelf(), encoder: VideoEncoder = AssetWriterEncoder(), probe: MediaProbing = AVProbe(),
        extractAudio: @escaping @Sendable (URL, URL) async throws -> Void = { try await AudioExtractor.extract(from: $0, to: $1) },
        reachability: ServerReachability = ServerReachability()
    ) {
        self.store = store
        self.shelf = shelf
        self.encoder = encoder
        self.probe = probe
        self.extractAudio = extractAudio
        self.reachability = reachability
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
        reachability.probe = { [weak self] in await self?.serverAnswers() ?? false }
        reachability.onRegained = { [weak self] in await self?.reconnected() }
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
        all = []
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
            report(error, quiet: true)
            return
        }
        people = (try? await api.people()) ?? []
        await reload()
        Task { await sendPending() }
        Task { await compressVideos() }
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            let reachability = self?.reachability
            let connected: @Sendable (Bool) -> Void = { up in
                Task { @MainActor in up ? await reachability?.answered() : reachability?.lost() }
            }
            guard let stream = self?.api?.events(connected: connected) else { return }
            for await event in stream where event.type.hasPrefix("recording.") || event.type == "settings.changed" {
                await self?.handle(event)
            }
        }
    }

    func handle(_ event: ServerEvent) async {
        if event.type == "settings.changed" {
            if let api, let fresh = try? await api.profile() { profile = fresh }
            return
        }
        await reload()
        if event["recordingId"] == selectedId { await loadDetail() }
        if event["status"] == RecordingStatus.done.rawValue || event["status"] == RecordingStatus.stored.rawValue {
            await mirrorNow()
        }
    }

    // MARK: Errors and the connection

    /// Shows an error in the alert. When the server cannot be reached and the
    /// call was a load or an upload (`quiet`), only the indicator in the
    /// sidebar changes: it repeats once the server is back.
    func report(_ error: any Error, quiet: Bool = false, as text: (String) -> String = { $0 }) {
        if APIError.isTransient(error) {
            reachability.lost()
            if quiet { return }
        }
        self.error = text(APIError.describe(error))
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

    /// Catches up on what changed while the server was away, and sends what waits.
    func reconnected() async {
        guard profile != nil else { return await start() }
        await reload()
        await loadDetail()
        await sendPending()
    }

    public var recordings: [RecordingSummary] {
        guard let kindFilter else { return all }
        return all.filter { $0.kind == kindFilter }
    }

    public func count(of kind: RecordingKind) -> Int { all.filter { $0.kind == kind }.count }

    /// Each recording's folder in iCloud Drive, by id, as of the last copy.
    public private(set) var folders: [String: URL] = [:]

    public func folder(of id: String) -> URL? { folders[id] }

    /// The shareable MP4 in the recording's folder, else the one or the raw
    /// original still on this Mac.
    public func video(of id: String) -> URL? {
        let fm = FileManager.default
        if let folder = folders[id],
           let mp4 = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
               .filter({ $0.pathExtension == "mp4" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
            return mp4
        }
        guard let item = shelf.item(forRecording: id) else { return nil }
        let url = shelf.url(item.video ?? item.original)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// The file to share or reveal: the video, else the audio in the folder.
    public func file(of id: String) -> URL? {
        if let video = video(of: id) { return video }
        let audio = folders[id]?.appendingPathComponent(Naming.audio)
        return audio.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    public var mirrorEnabled: Bool { profile?.settings?["pensieve.mirror"]?.bool ?? true }

    // MARK: Lists

    public func reload() async {
        guard let api else { return }
        do {
            all = try await api.recordings(scope: scope, query: query.isEmpty ? nil : query, labels: labelFilter.sorted())
            labels = (try? await api.labels()) ?? labels
            folders = mirror.folders()
            keepSelection()
        } catch {
            report(error, quiet: true)
        }
    }

    private func keepSelection() {
        if selectedId == nil || !recordings.contains(where: { $0.id == selectedId }) {
            selectedId = recordings.first?.id
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

    /// Puts a finished call or dictation in the outbox and sends it; on
    /// failure it waits there for the next try.
    public func finished(
        audio: URL, kind: RecordingKind = .call, title: String, startedAt: Date, marks: [Mark] = [], labels: [String] = [],
        transcribe: Bool? = nil
    ) async {
        let upload = PendingUpload(
            kind: kind, title: title, startedAt: startedAt, audio: audio.lastPathComponent, marks: marks, labels: labels,
            transcribe: transcribe)
        do {
            try outbox.add(upload)
        } catch {
            self.error = "De opname kon niet in de wachtrij: \(error.localizedDescription)"
        }
        pending = outbox.all()
        await sendPending()
    }

    /// A finished video or screen recording: its sound goes to the server
    /// (transcribed only when asked, unless `transcribe`), the picture stays
    /// on the shelf until the shareable MP4 is safely in iCloud.
    public func finishedVideo(
        original: URL, kind: RecordingKind, title: String, startedAt: Date, marks: [Mark] = [], labels: [String] = [],
        format: RecordingFormat = .normal, transcribe: Bool? = nil
    ) async {
        let id = UUID().uuidString
        do {
            try shelf.save(ShelfItem(id: id, kind: kind, title: title, startedAt: startedAt, original: original.path, format: format))
            let audio = try outbox.newAudioFile(extension: "m4a")
            try await extractAudio(original, audio)
            try outbox.add(PendingUpload(
                id: id, kind: kind, title: title, startedAt: startedAt, audio: audio.lastPathComponent, marks: marks,
                labels: labels, transcribe: transcribe))
        } catch {
            self.error = "Het geluid van de opname kon niet apart worden gezet: \(error.localizedDescription). De video staat nog op deze Mac."
        }
        pending = outbox.all()
        await sendPending()
        await compressVideos()
    }

    /// Makes the shareable MP4 of every video still raw, then copies it to
    /// iCloud. A call while one runs waits for it and is picked up by it.
    public func compressVideos() async {
        compressAgain = true
        if let compression { return await compression.value }
        let task = Task {
            while compressAgain {
                compressAgain = false
                await shelf.compressPending(encoder: encoder, probe: probe)
            }
            if shelf.all().contains(where: { $0.video != nil && $0.recordingId != nil }) { await mirrorNow() }
        }
        compression = task
        await task.value
        compression = nil
    }

    /// A dictation: sends the audio and waits for the text, to paste it.
    /// When the server is away it waits in the outbox and this throws.
    public func dictate(audio: URL, startedAt: Date, labels: [String] = [], timeout: Duration = .seconds(60)) async throws -> RecordingDetail {
        guard let api else { throw APIError.unauthorized }
        let upload = PendingUpload(
            kind: .dictation, title: RecordingDefaults.name(of: .dictation), startedAt: startedAt, audio: audio.lastPathComponent,
            labels: labels)
        try outbox.add(upload)
        pending = outbox.all()
        let created = try await outbox.send(upload, api: api)
        pending = outbox.all()
        let detail = try await api.waitForTranscript(created.id, timeout: timeout)
        await reload()
        return detail
    }

    /// Title and labels for a new recording of this kind.
    public func suggestion(for kind: RecordingKind) -> (title: String, labels: [String]) {
        RecordingDefaults.suggestion(for: kind, after: all)
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
                shelf.bind(upload.id, to: created.id)
                pending = outbox.all()
                await reload()
                if upload.source == "recorded", upload.kind != .dictation { selectedId = created.id }
            } catch {
                uploadProgress[upload.id] = nil
                pending = outbox.all()
                report(error, quiet: true) { "Uploaden lukt nu niet; Pensieve probeert het later opnieuw. (\($0))" }
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

    /// "Maak transcript": only the audio goes to the server.
    public func requestTranscript(_ id: String) async {
        await act { try await $0.requestTranscript(id) }
    }

    public func setLabels(_ id: String, _ labels: [String]) async {
        await act { try await $0.setLabels(recording: id, labels) }
    }

    public func setMarks(_ id: String, _ marks: [Mark]) async {
        await act { _ = try await $0.setMarks(recording: id, marks); return nil }
    }

    public func addLabel(_ name: String) async {
        await act { _ = try await $0.addLabel(name); return nil }
    }

    public func renameLabel(_ id: String, to name: String) async {
        await act { _ = try await $0.renameLabel(id, to: name); return nil }
    }

    public func deleteLabel(_ id: String) async {
        await act { try await $0.deleteLabel(id); return nil }
    }

    public func delete(_ id: String) async {
        guard let api else { return }
        do {
            try await api.deleteRecording(id)
            if selectedId == id { selectedId = nil }
            await reload()
        } catch {
            report(error)
        }
    }

    private func act(_ change: (APIClient) async throws -> RecordingSummary?) async {
        guard let api else { return }
        do {
            _ = try await change(api)
            await reload()
            await loadDetail()
        } catch {
            report(error)
        }
    }

    /// The other people of the household, for the share menu.
    public var others: [Person] { people.filter { $0.id != profile?.person.id } }

    // MARK: iCloud and RecHoarder

    /// Video and screen recordings go to iCloud even with the copy off:
    /// their folder is the video's only home.
    public func mirrorNow() async {
        guard let api else { return }
        do {
            let all = try await api.recordings(scope: .all)
            try await mirror.sync(mirrorEnabled ? all : all.filter { $0.kind.hasVideo && $0.mine }, api: api, shelf: shelf)
            lastMirror = Date()
            folders = mirror.folders()
        } catch {
            report(error, quiet: true) { "De kopie in iCloud Drive lukte niet: \($0)" }
        }
    }

    static let importedKey = "app.burrow.pensieve.imported"

    public var importedFolders: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.importedKey) ?? [])
    }

    private func markImported(_ slug: String) {
        UserDefaults.standard.set(Array(importedFolders.union([slug])).sorted(), forKey: Self.importedKey)
    }

    /// Queues every RecHoarder meeting not imported before and starts sending
    /// them; gigabytes of audio take a while, so this does not wait for that.
    /// Returns how many were queued and how many wait for iCloud.
    @discardableResult
    public func importRecHoarder(from source: RecHoarderImport = RecHoarderImport()) -> (queued: Int, waiting: Int) {
        let queuedAlready = Set(outbox.all().compactMap(\.importedFrom))
        let scan = source.scan(skipping: importedFolders.union(queuedAlready))
        for upload in scan.ready { try? outbox.add(upload) }
        pending = outbox.all()
        Task { await sendPending() }
        return (scan.ready.count, scan.downloading.count)
    }
}
