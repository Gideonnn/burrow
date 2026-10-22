import Foundation

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
            outing = try await api.createOuting(request)
            outingSuggestion?.outingId = outing?.id
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func setOutingTask(_ task: OutingTask, done: Bool) async {
        guard let api, let id = outing?.id else { return }
        do {
            outing = try await api.setOutingTask(outingId: id, taskId: task.id, done: done)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Writes the ticket to a temporary file the app can open with Preview or
    /// Wallet; it never leaves the Mac.
    public func ticketURL(_ ticket: OutingTicket) async -> URL? {
        guard let api, let id = outing?.id else { return nil }
        do {
            let data = try await api.ticketFile(outingId: id, ticketId: ticket.id)
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
}
