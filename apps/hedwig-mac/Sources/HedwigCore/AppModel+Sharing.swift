import Foundation

// MARK: Sharing a mail with the household

extension AppModel {
    /// The others in the household, whom a mail can be shared with.
    public var housemates: [Person] { people.filter { $0.id != me?.person.id } }

    public func personName(_ id: String) -> String {
        people.first { $0.id == id }?.name ?? "je huisgenoot"
    }

    /// "Angela", or "Angela en Bram" in a bigger household.
    public var housematesTitle: String {
        let names = housemates.map(\.name)
        guard let last = names.last else { return "je huisgenoot" }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " en " + last
    }

    /// Mail someone else shared with this person: it can be read, never organized or answered.
    public var detailIsMine: Bool { detail?.share?.by == nil }

    /// Shares the open mail with everyone else in the household, or takes the share back.
    public func toggleShare() async {
        guard let api, let message = detail, detailIsMine else { return }
        let shared = message.share?.with ?? []
        do {
            var updated: MessageSummary?
            if shared.isEmpty {
                for person in housemates { updated = try await api.share(messageId: message.id, with: person.id) }
            } else {
                for id in shared { updated = try await api.unshare(messageId: message.id, from: id) }
            }
            if let updated { await sharingChanged(updated) }
        } catch {
            report(error)
        }
    }

    /// Deel or Niet on Winky's suggestion; `always` holds for every later mail from the sender.
    public func decideShareSuggestion(share: Bool, always: Bool = false) async {
        guard let api, let message = detail else { return }
        do {
            let updated = try await api.decideShareSuggestion(messageId: message.id, share: share, always: always)
            await sharingChanged(updated)
        } catch {
            report(error)
        }
    }

    /// Gedeeld: Winky's suggestions first, then what others shared with this
    /// person, then what this person shared.
    func sharedMessages() async throws -> [MessageSummary] {
        guard let api else { return [] }
        await loadPeople()
        let suggested = (try? await api.shareSuggestions().suggestions.map(\.message)) ?? []
        let shared = try await api.shared()
        var seen = Set<String>()
        return (suggested + shared.withMe + shared.byMe).filter { seen.insert($0.id).inserted }
    }

    private func sharingChanged(_ updated: MessageSummary) async {
        if selection == .shared, !isSearching {
            await loadSelection(keepSelection: true)
        } else if let index = messages.firstIndex(where: { $0.id == updated.id }) {
            messages[index] = updated
        }
        await openSelected()
    }
}
