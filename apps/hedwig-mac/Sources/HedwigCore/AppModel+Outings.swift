import Foundation

// MARK: The card above a mail

extension AppModel {
    /// Asks the server whether the open mail is about an outing. Cheap: the
    /// server only fetches attachments when the mail looks like one.
    func loadOuting(messageId: String) async {
        guard let api, me?.can(.read) == true else { return }
        guard let suggestion = try? await api.outingSuggestion(messageId: messageId),
              selectedMessageId == messageId else { return }
        outingSuggestion = suggestion
        if let id = suggestion.outingId {
            outing = try? await api.outing(id: id)
        } else {
            outing = nil
        }
    }

    /// The card shows when the mail belongs to an outing or looks like one.
    public var showsOutingCard: Bool {
        outing != nil || (outingSuggestion?.confidence ?? .none) != .none
    }

    /// One click: the outing with everything read from the mail, its ticket
    /// attachments kept and the mail linked.
    public func saveOuting() async {
        guard let api, let suggestion = outingSuggestion, let messageId = detail?.id else { return }
        guard let request = CreateOutingRequest(suggestion: suggestion, messageId: messageId) else {
            error = "Hedwig vond geen datum in deze mail. Maak het evenement zelf aan onder Evenementen."
            return
        }
        outingBusy = true
        defer { outingBusy = false }
        do {
            let saved = try await api.createOuting(request)
            apply(saved)
            outing = saved
            outingSuggestion?.outingId = saved.id
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: The Evenementen page

extension AppModel {
    public func refreshOutings() async {
        guard let api, me?.can(.read) == true else { return }
        guard let list = try? await api.outings() else { return }
        outings = list
        if selection == .outings, selectedOutingId == nil || !list.contains(where: { $0.id == selectedOutingId }) {
            selectedOutingId = upcomingOutings.first?.id ?? pastOutings.first?.id
        }
    }

    public func upcomingOutings(now: Date = .now) -> [Outing] {
        outings.filter { !$0.isPast(now: now) }.sorted { $0.startsAt < $1.startsAt }
    }

    public var upcomingOutings: [Outing] { upcomingOutings() }

    /// Geweest, the most recent first.
    public var pastOutings: [Outing] {
        outings.filter { $0.isPast() }.sorted { $0.startsAt > $1.startsAt }
    }

    public var selectedOuting: Outing? { outings.first { $0.id == selectedOutingId } }

    /// The sidebar badge: outings that need something now.
    public func outingsNeedingAttention(now: Date = .now) -> Int {
        outings.filter { $0.needsAttention(now: now) }.count
    }

    public var outingsBadge: Int { outingsNeedingAttention() }

    /// What the Mac reminds its person of until Patronus does it on Telegram:
    /// only outings they go to. macOS keeps at most 64 pending notifications
    /// per app, so the nearest ones win.
    public func outingReminders(now: Date = .now) -> [OutingReminder] {
        let mine = upcomingOutings(now: now).filter { outing in
            me.map { me in outing.attendees.contains { $0.id == me.person.id } } ?? false
        }
        return Array(mine.flatMap { $0.reminders(now: now) }.sorted { $0.fireAt < $1.fireAt }.prefix(60))
    }

    /// Opens the outing on the Evenementen page, from the mail card or a notification.
    public func showOuting(_ id: String) {
        selectedOutingId = id
        selection = .outings
    }

    public func loadPeople() async {
        guard people.isEmpty, let api else { return }
        people = (try? await api.people()) ?? []
    }

    /// Nieuw evenement: what, when and where; tickets dropped on the sheet follow.
    @discardableResult
    public func createOuting(title: String, startsAt: Date, venue: String, tickets: [URL] = []) async -> Outing? {
        guard let api else { return nil }
        let place = venue.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CreateOutingRequest(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), startsAt: startsAt, venue: place.isEmpty ? nil : place)
        do {
            let created = try await api.createOuting(request)
            apply(created)
            selectedOutingId = created.id
            if !tickets.isEmpty { await addTickets(tickets, to: created.id) }
            return created
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Changes fields; `.null` clears one. The answer replaces the outing.
    public func updateOuting(_ id: String, _ patch: [String: JSONValue]) async {
        await change { try await $0.updateOuting(id: id, patch) }
    }

    public func setTask(_ task: OutingTask, done: Bool, in outingId: String) async {
        await change { try await $0.setOutingTask(outingId: outingId, taskId: task.id, done: done) }
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
        await updateOuting(outing.id, ["attendeeIds": .array(ids.map(JSONValue.string))])
    }

    public func setAliases(_ aliases: [String], in outingId: String) async {
        await updateOuting(outingId, ["aliases": .array(aliases.map(JSONValue.string))])
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

    public func deleteOuting(_ id: String) async {
        guard let api else { return }
        do {
            try await api.deleteOuting(id: id)
            outings.removeAll { $0.id == id }
            if outing?.id == id { outing = nil }
            if selectedOutingId == id { selectedOutingId = upcomingOutings.first?.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The files Hedwig keeps as tickets: what the server recognises.
    public static let ticketExtensions: Set<String> = ["pdf", "pkpass", "png", "jpg", "jpeg", "heic", "webp"]

    /// Uploads files (dropped or picked) and keeps them as tickets.
    public func addTickets(_ files: [URL], to outingId: String) async {
        guard let api else { return }
        let usable = files.filter { $0.isFileURL && Self.ticketExtensions.contains($0.pathExtension.lowercased()) }
        if usable.count < files.count { error = "Hedwig bewaart alleen pdf, Wallet-pas of afbeelding als kaart." }
        for file in usable {
            ticketUploads += 1
            defer { ticketUploads -= 1 }
            do {
                let upload = try await api.upload(file: file)
                apply(try await api.addTicket(outingId: outingId, uploadId: upload, name: file.lastPathComponent))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Writes the ticket to a temporary file the app can open with Preview or
    /// Wallet; it never leaves the Mac.
    public func ticketURL(_ ticket: OutingTicket, in outingId: String) async -> URL? {
        guard let api else { return nil }
        do {
            let data = try await api.ticketFile(outingId: outingId, ticketId: ticket.id)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hedwig-tickets/\(ticket.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(ticket.name.replacingOccurrences(of: "/", with: "-"))
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// A linked mail in Hedwig's own message view, in the list it lives in.
    public func openMail(_ id: String) async {
        guard let api else { return }
        do {
            let message = try await api.message(id: id)
            selection = message.folder == .inbox ? .inbox(mailboxId: message.mailboxId) : .folder(message.folder)
            await selectionLoad?.value
            if !messages.contains(where: { $0.id == id }) { messages.insert(message.summary, at: 0) }
            selectedMessageId = id
            await messageLoad?.value
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func change(_ call: (APIClient) async throws -> Outing) async {
        guard let api else { return }
        do {
            apply(try await call(api))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Puts a changed outing in the list and on the mail card.
    func apply(_ updated: Outing) {
        if let index = outings.firstIndex(where: { $0.id == updated.id }) {
            outings[index] = updated
        } else {
            outings.append(updated)
        }
        if outing?.id == updated.id { outing = updated }
    }
}
