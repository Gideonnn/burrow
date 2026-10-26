import BurrowKit
import Foundation
import HedwigCore
import Observation

/// Hogsmeade's state and every action its two faces take: the household's
/// outings from the server, which one is open, the search, and the changes
/// (tasks, who goes, tickets, pictures). A state machine without a window,
/// so the tests drive it like the faces do. The outings are Hedwig's: the
/// same routes, the same types, the same `outing.changed` events.
@MainActor
@Observable
public final class OutingsModel {
    public enum Page: String, CaseIterable, Sendable {
        case upcoming, past
    }

    /// The sidebar's narrowing: who goes, or what kind of outing.
    public enum Filter: Hashable, Sendable {
        case person(String)
        case kind(String)
    }

    public struct Toast: Equatable, Sendable {
        public var message: String
        public var id = UUID()
    }

    /// What just happened, for a face that wants to celebrate it.
    public struct ChangeNote: Equatable, Sendable {
        public enum Kind: Sendable { case created, taskDone, allDone, ticketsAdded }

        public var kind: Kind
        public var outingId: String
        public var id = UUID()
    }

    public private(set) var connection: Connection?
    public private(set) var me: Me?
    public private(set) var people: [Person] = []
    public private(set) var outings: [Outing] = []
    public private(set) var isLoading = false
    public var error: String?
    public let reachability: ServerReachability

    public var page: Page = .upcoming
    public var filter: Filter?
    /// The playful face: the wall instead of the night itself, when someone asked for it.
    public var tonightHidden = false
    public var query = ""
    public private(set) var openId: String?
    public private(set) var toast: Toast?
    public private(set) var lastChange: ChangeNote?
    public private(set) var ticketUploads = 0
    /// Bumped by ⌘N and ⌘F; the faces open the sheet and focus the search.
    public var newRequest = 0
    public var searchFocusRequest = 0
    public private(set) var pictureBusy: Set<String> = []

    @ObservationIgnored public let pictureCache = OutingPictureCache()
    private let store: ConnectionStore
    private let makeClient: @Sendable (Connection) -> APIClient
    /// Where the last outings are kept, so the window opens full before the
    /// server has answered; nil keeps nothing (tests).
    private let cacheDirectory: URL?
    private var eventsTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    /// Off in tests, so a toast stays until the next one.
    var toastSeconds: Double? = 4
    /// The clock, so the tests can set the day.
    public var now: () -> Date = { .now }

    public init(
        store: ConnectionStore,
        makeClient: @escaping @Sendable (Connection) -> APIClient = { APIClient(baseURL: $0.serverURL, token: $0.token) },
        connection: Connection? = nil,
        reachability: ServerReachability = ServerReachability(),
        cacheDirectory: URL? = nil
    ) {
        self.store = store
        self.makeClient = makeClient
        self.reachability = reachability
        self.cacheDirectory = cacheDirectory
        // HOGSMEADE_SERVER and HOGSMEADE_KEY connect without the Keychain, for
        // demos and automated runs against a development server.
        let environment = ProcessInfo.processInfo.environment
        if connection == nil, let server = environment["HOGSMEADE_SERVER"].flatMap(URL.init(string:)),
           let key = environment["HOGSMEADE_KEY"] {
            self.connection = Connection(serverURL: server, token: key)
        } else {
            self.connection = connection ?? store.load()
        }
        reachability.probe = { [weak self] in await self?.serverAnswers() ?? false }
        reachability.onRegained = { [weak self] in await self?.refresh() }
    }

    public var api: APIClient? { connection.map(makeClient) }
    public var myName: String { me?.person.name ?? "jij" }
    public var myId: String? { me?.person.id }
    public var canOrganize: Bool { me?.can(.organize) == true }

    // MARK: Connecting

    public func connect(serverURL: URL, token: String) async throws {
        let candidate = Connection(serverURL: serverURL, token: token)
        me = try await makeClient(candidate).me()
        try store.save(candidate)
        connection = candidate
        await start()
    }

    public func logout() {
        eventsTask?.cancel()
        store.clear()
        connection = nil
        me = nil
        outings = []
        openId = nil
    }

    public func start() async {
        guard let api else { return }
        if outings.isEmpty, let kept = readSnapshot() { outings = kept }
        do {
            async let me = api.me()
            async let people = api.people()
            self.me = try await me
            self.people = (try? await people) ?? []
        } catch APIError.unauthorized {
            logout()
            error = APIError.unauthorized.errorDescription
            return
        } catch {
            report(error, quiet: true)
            return
        }
        await refresh()
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            let reachability = self?.reachability
            let connected: @Sendable (Bool) -> Void = { up in
                Task { @MainActor in up ? await reachability?.answered() : reachability?.lost() }
            }
            guard let stream = self?.api?.events(connected: connected) else { return }
            for await event in stream {
                switch event.type {
                case "outing.changed": await self?.refresh()
                case "settings.changed", "household.changed":
                    if let api = self?.api {
                        self?.me = (try? await api.me()) ?? self?.me
                        self?.people = (try? await api.people()) ?? self?.people ?? []
                    }
                default: break
                }
            }
        }
    }

    public func refresh() async {
        guard let api else { return }
        isLoading = outings.isEmpty
        defer { isLoading = false }
        do {
            let list = try await api.outings()
            outings = list
            writeSnapshot(list)
            if let openId, !list.contains(where: { $0.id == openId }) { self.openId = nil }
        } catch {
            report(error, quiet: true)
        }
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

    func report(_ error: any Error, quiet: Bool = false) {
        if APIError.isTransient(error) {
            reachability.lost()
            if quiet { return }
        }
        self.error = APIError.describe(error)
    }

    // MARK: The snapshot on disk

    private var snapshotFile: URL? { cacheDirectory?.appendingPathComponent("outings.json") }

    private static let snapshotEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(APIClient.isoFractional.string(from: date))
        }
        return encoder
    }()

    private func readSnapshot() -> [Outing]? {
        guard let file = snapshotFile, let data = try? Data(contentsOf: file) else { return nil }
        return try? APIClient.decoder.decode([Outing].self, from: data)
    }

    private func writeSnapshot(_ list: [Outing]) {
        guard let file = snapshotFile, let data = try? Self.snapshotEncoder.encode(list) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: What the faces show

    /// Still to come, the nearest first; today's outing is the first.
    public var upcoming: [Outing] {
        let now = now()
        return outings.filter { !$0.isPast(now: now) }.sorted { $0.startsAt < $1.startsAt }
    }

    /// Geweest, the most recent first.
    public var past: [Outing] {
        let now = now()
        return outings.filter { $0.isPast(now: now) }.sorted { $0.startsAt > $1.startsAt }
    }

    /// The outing on today's date, when there is one: the night takes over.
    public var today: Outing? {
        let now = now()
        return upcoming.first { $0.isToday(now: now) }
    }

    /// The first outing that is still to come: what the greeting counts to.
    public var next: Outing? { upcoming.first }

    /// What the page shows after the sidebar's filter and the search.
    public var shown: [Outing] {
        let base = page == .upcoming ? upcoming : past
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        return base.filter { outing in
            guard matches(outing, filter) else { return false }
            guard !words.isEmpty else { return true }
            return [outing.title, outing.kind, outing.venue, outing.address, outing.organiser]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(words) }
        }
    }

    private func matches(_ outing: Outing, _ filter: Filter?) -> Bool {
        switch filter {
        case nil: true
        case .person(let id): outing.attendees.contains { $0.id == id }
        case .kind(let kind): Self.kindKey(outing.kind) == kind
        }
    }

    public static func kindKey(_ kind: String?) -> String? {
        guard let kind = kind?.trimmingCharacters(in: .whitespaces).lowercased(), !kind.isEmpty else { return nil }
        return kind
    }

    /// The kinds among the upcoming outings with how many there are, for the sidebar.
    public var kinds: [(key: String, label: String, count: Int)] {
        var counts: [String: (label: String, count: Int)] = [:]
        for outing in upcoming {
            guard let key = Self.kindKey(outing.kind) else { continue }
            let label = outing.kind?.trimmingCharacters(in: .whitespaces) ?? key
            counts[key, default: (label.prefix(1).uppercased() + label.dropFirst(), 0)].count += 1
        }
        return counts.map { ($0.key, $0.value.label, $0.value.count) }.sorted { $0.count > $1.count || ($0.count == $1.count && $0.key < $1.key) }
    }

    /// How many upcoming outings each person goes to, for the sidebar.
    public func count(for person: Person) -> Int {
        upcoming.filter { $0.attendees.contains { $0.id == person.id } }.count
    }

    /// Upcoming outings that need something now.
    public var attentionCount: Int {
        let now = now()
        return outings.filter { $0.needsAttention(now: now) }.count
    }

    /// "6 uitjes · 2 dingen te doen"
    public var summaryLine: String {
        let n = upcoming.count
        var parts = [n == 1 ? "1 uitje" : "\(n) uitjes"]
        let todo = attentionCount
        if todo > 0 { parts.append(todo == 1 ? "1 ding te doen" : "\(todo) dingen te doen") }
        return parts.joined(separator: " · ")
    }

    public var open: Outing? { openId.flatMap { id in outings.first { $0.id == id } } }

    public func open(_ id: String) { openId = id }
    public func close() { openId = nil }

    /// Esc: the open outing, then the search.
    public func escape() {
        if openId != nil {
            openId = nil
        } else if !query.isEmpty {
            query = ""
        }
    }

    /// Nights between today and the outing, 0 on the day itself.
    public func nights(until outing: Outing, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: now())
        let to = calendar.startOfDay(for: outing.startsAt)
        return max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    }

    /// "nog 3 nachtjes", "morgen!", "vanavond!"
    public func nightsLabel(_ outing: Outing) -> String {
        let n = nights(until: outing)
        switch n {
        case 0: return outing.dayWord().lowercased() + "!"
        case 1: return "morgen!"
        default: return "nog \(n) nachtjes"
        }
    }

    /// The names of the others who go, for "samen met Eva".
    public func others(on outing: Outing) -> [String] {
        outing.attendees.filter { $0.id != myId }.map(\.name)
    }

    public static func sentence(_ names: [String]) -> String? {
        switch names.count {
        case 0: nil
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " en " + names[names.count - 1]
        }
    }

    // MARK: Changes

    private func change(_ call: (APIClient) async throws -> Outing, saying label: String? = nil) async -> Outing? {
        guard let api else { return nil }
        do {
            let updated = try await call(api)
            apply(updated)
            if let label { show(label) }
            return updated
        } catch {
            report(error)
            return nil
        }
    }

    func apply(_ updated: Outing) {
        if let index = outings.firstIndex(where: { $0.id == updated.id }) {
            outings[index] = updated
        } else {
            outings.append(updated)
        }
        writeSnapshot(outings)
    }

    /// Nieuw uitje: what, when and where; everyone goes until someone says otherwise.
    @discardableResult
    public func create(title: String, startsAt: Date, venue: String, kind: String? = nil) async -> Outing? {
        let place = venue.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = CreateOutingRequest(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), startsAt: startsAt, venue: place.isEmpty ? nil : place)
        request.kind = kind?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard let created = await change({ try await $0.createOuting(request) }) else { return nil }
        lastChange = ChangeNote(kind: .created, outingId: created.id)
        show("\(created.title) hangt aan de wand.")
        openId = created.id
        return created
    }

    public func update(_ id: String, _ patch: [String: JSONValue]) async {
        await change { try await $0.updateOuting(id: id, patch) }
    }

    public func setTask(_ task: OutingTask, done: Bool, in outing: Outing) async {
        guard let updated = await change({ try await $0.setOutingTask(outingId: outing.id, taskId: task.id, done: done) }) else { return }
        if done {
            let allDone = updated.openItems().isEmpty && !updated.tickets.isEmpty
            lastChange = ChangeNote(kind: allDone ? .allDone : .taskDone, outingId: outing.id)
            show(allDone ? "Alles geregeld voor \(updated.title)!" : "\(task.title) gedaan.")
        }
    }

    public func addTask(title: String, dueAt: Date?, to outingId: String) async {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await change { try await $0.addOutingTask(outingId: outingId, title: text, dueAt: dueAt) }
    }

    /// Wie: adds the person to the outing or takes them off it.
    public func toggleAttendee(_ person: Person, in outing: Outing) async {
        var ids = outing.attendees.map(\.id)
        if let index = ids.firstIndex(of: person.id) { ids.remove(at: index) } else { ids.append(person.id) }
        await update(outing.id, ["attendeeIds": .array(ids.map(JSONValue.string))])
    }

    public func delete(_ id: String) async {
        guard let api else { return }
        do {
            try await api.deleteOuting(id: id)
            outings.removeAll { $0.id == id }
            if openId == id { openId = nil }
            writeSnapshot(outings)
        } catch {
            report(error)
        }
    }

    // MARK: Tickets

    public static let ticketExtensions: Set<String> = ["pdf", "pkpass", "png", "jpg", "jpeg", "heic", "webp"]

    /// Uploads files (dropped or picked) and keeps them as tickets.
    public func addTickets(_ files: [URL], to outingId: String) async {
        guard let api else { return }
        let usable = files.filter { $0.isFileURL && Self.ticketExtensions.contains($0.pathExtension.lowercased()) }
        if usable.count < files.count { error = "Alleen een pdf, een Wallet-pas of een afbeelding kan een kaartje zijn." }
        var added = 0
        for file in usable {
            ticketUploads += 1
            defer { ticketUploads -= 1 }
            do {
                let upload = try await api.upload(file: file)
                apply(try await api.addTicket(outingId: outingId, uploadId: upload, name: file.lastPathComponent))
                added += 1
            } catch {
                report(error)
            }
        }
        if added > 0 {
            lastChange = ChangeNote(kind: .ticketsAdded, outingId: outingId)
            show(added == 1 ? "Kaartje bewaard." : "\(added) kaartjes bewaard.")
        }
    }

    public func updateTicket(_ ticket: OutingTicket, in outingId: String, holder: String?? = nil, personalised: Bool? = nil) async {
        var patch: [String: JSONValue] = [:]
        if let holder { patch["holder"] = holder.map(JSONValue.string) ?? .null }
        if let personalised { patch["personalised"] = .bool(personalised) }
        await change { try await $0.updateTicket(outingId: outingId, ticketId: ticket.id, patch) }
    }

    public func deleteTicket(_ ticket: OutingTicket, in outingId: String) async {
        await change { try await $0.deleteTicket(outingId: outingId, ticketId: ticket.id) }
    }

    /// The ticket's bytes for its code; a failure only leaves the code out.
    public func ticketData(_ ticket: OutingTicket, in outingId: String) async -> Data? {
        try? await api?.ticketFile(outingId: outingId, ticketId: ticket.id)
    }

    /// Writes the ticket to a temporary file Preview or Wallet can open.
    public func ticketURL(_ ticket: OutingTicket, in outingId: String) async -> URL? {
        guard let api else { return nil }
        do {
            let data = try await api.ticketFile(outingId: outingId, ticketId: ticket.id)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hogsmeade-tickets/\(ticket.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(ticket.name.replacingOccurrences(of: "/", with: "-"))
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: Pictures

    public func picture(for outing: Outing) async -> OutingPicture? {
        guard let api, let image = outing.image else { return nil }
        return await pictureCache.picture(outing.id, version: image.updatedAt) {
            guard let data = try? await api.outingImage(outingId: outing.id, version: image.updatedAt) else { return nil }
            return OutingPicture(data: data)
        }
    }

    public func cachedPicture(for outing: Outing) -> OutingPicture? {
        guard let image = outing.image else { return nil }
        return pictureCache.cached(outing.id, version: image.updatedAt) ?? nil
    }

    public func pictureOptions(for outingId: String) async -> [OutingImageOption] {
        guard let api else { return [] }
        return (try? await api.outingImageOptions(outingId: outingId)) ?? []
    }

    public func pictureOption(_ option: OutingImageOption, of outingId: String) async -> OutingPicture? {
        guard let api, let data = try? await api.outingImageOption(outingId: outingId, optionId: option.id) else { return nil }
        return OutingPicture(data: data)
    }

    public func choosePicture(_ option: OutingImageOption, for outingId: String) async {
        await changePicture(outingId) { try await $0.setOutingImage(outingId: outingId, .option(option.id)) }
    }

    public func removePicture(from outingId: String) async {
        await changePicture(outingId) { try await $0.deleteOutingImage(outingId: outingId) }
    }

    /// A pasted or dropped picture, or a link to one or to a page with one.
    public func setPicture(_ contents: PastedContents, for outingId: String) async {
        guard let pasted = PastedPicture(contents) else {
            error = contents.isEmpty
                ? "Kopieer eerst een afbeelding of een link naar een website."
                : "Dat is geen afbeelding. Kopieer een afbeelding of een link naar een website."
            return
        }
        await changePicture(outingId) { api in
            switch pasted {
            case .link(let url):
                return try await api.setOutingImage(outingId: outingId, .link(url))
            case .image(let data):
                return try await api.setOutingImage(outingId: outingId, .upload(try await Self.uploadPicture(data, api)))
            case .file(let file):
                let data = try Data(contentsOf: file)
                return try await api.setOutingImage(outingId: outingId, .upload(try await Self.uploadPicture(data, api)))
            }
        }
    }

    private static func uploadPicture(_ data: Data, _ api: APIClient) async throws -> String {
        guard let prepared = PictureUpload.prepare(data) else { throw PictureError.notAPicture }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hogsmeade-pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).\(prepared.fileExtension)")
        try prepared.data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await api.upload(file: file)
    }

    private func changePicture(_ outingId: String, _ call: (APIClient) async throws -> Outing) async {
        guard let api else { return }
        pictureBusy.insert(outingId)
        defer { pictureBusy.remove(outingId) }
        do {
            apply(try await call(api))
        } catch PictureError.notAPicture, APIError.server(status: 400, _) {
            error = "Daar kan Hogsmeade geen afbeelding van maken. Probeer een andere afbeelding of link."
        } catch {
            report(error)
        }
    }

    // MARK: Line-up

    public func refreshLineup(_ outingId: String) async {
        await change { try await $0.refreshLineup(outingId: outingId) }
    }

    public func removeLineup(_ outingId: String) async {
        await change { try await $0.removeLineup(outingId: outingId) }
    }

    // MARK: The toast

    public func show(_ message: String) {
        let next = Toast(message: message)
        toast = next
        toastTask?.cancel()
        guard let seconds = toastSeconds else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled, self?.toast?.id == next.id { self?.toast = nil }
        }
    }
}

enum PictureError: Error { case notAPicture }

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: What a poster says

public struct WallStamp: Equatable, Sendable {
    public enum Tone: Sendable { case ok, todo, tickets }
    public var text: String
    public var tone: Tone
}

extension Outing {
    /// The one stamp on a poster: tickets missing, something to do, or all set.
    public func wallStamp() -> WallStamp {
        if tickets.isEmpty && shopLinks.isEmpty { return WallStamp(text: "Kaartjes?", tone: .tickets) }
        if !openItems().isEmpty { return WallStamp(text: "Nog doen", tone: .todo) }
        return WallStamp(text: "Geregeld!", tone: .ok)
    }

    /// "Feest · De Kolenloods"
    public var kindAndVenue: String {
        [kind.map { $0.prefix(1).uppercased() + $0.dropFirst() }, venue].compactMap { $0 }.joined(separator: " · ")
    }

    /// The city alone, for "De Kolenloods, Amsterdam".
    public var city: String? {
        OutingFormat.whereLines(venue: venue, address: address).dropFirst().first?.split(separator: ",").last?.trimmingCharacters(in: .whitespaces)
    }
}
