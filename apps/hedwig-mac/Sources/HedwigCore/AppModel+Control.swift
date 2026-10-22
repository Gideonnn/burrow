import Foundation

/// What an agent controlling Hedwig reads as `state`, and the app-level
/// commands that are easier than finding the right row in the tree.
extension AppModel {
    public func controlState() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var state: [String: Any] = [
            "connected": connection?.serverURL.host() ?? NSNull(),
            "serverReachable": reachability.isReachable,
            "selection": selectionName ?? NSNull(),
            "mailboxes": (me?.mailboxes ?? []).map {
                [
                    "id": $0.id, "address": $0.address, "name": $0.name, "role": $0.kind.rawValue,
                    "provider": $0.provider.rawValue, "unread": unreadCounts[$0.id] ?? 0,
                ] as [String: Any]
            },
            "messages": messages.map { message in
                [
                    "id": message.id, "mailboxId": message.mailboxId, "from": message.from.formatted,
                    "subject": message.subject, "snippet": message.snippet,
                    "receivedAt": iso.string(from: message.receivedAt), "unread": message.unread,
                    "flagged": message.flagged, "folder": message.folder.rawValue,
                ] as [String: Any]
            },
            "selectedMessageId": selectedMessageId ?? NSNull(),
            "drafts": drafts.count,
            "filtered": filtered.count,
            "tasksAwaitingReview": tasksAwaitingReview,
            "outingsNeedingAttention": outingsBadge,
        ]
        if let detail {
            state["message"] = [
                "id": detail.id, "from": detail.from.formatted, "to": Address.format(detail.to),
                "cc": Address.format(detail.cc), "subject": detail.subject,
                "receivedAt": iso.string(from: detail.receivedAt), "labels": detail.labels,
                "body": detail.bodyText ?? "",
            ] as [String: Any]
        }
        if let error { state["error"] = error }
        return state
    }

    private var selectionName: String? {
        switch selection {
        case .inbox(let id): "inbox:\(mailbox(id)?.address ?? id)"
        case .drafts(let id): "drafts:\(mailbox(id)?.address ?? id)"
        case .tasks: "tasks"
        case .outings: "outings"
        case .folder(let folder, let id): "\(folder.rawValue):\(mailbox(id)?.address ?? id)"
        case nil: nil
        }
    }

    /// `inbox`, `archive`, `sent`, `spam` or `drafts` of the open mailbox (the
    /// first one elsewhere), each also as `<place>:<address>`; a role (`private`,
    /// `work`, `school`: the inbox of its first mailbox); `filtered` (the first
    /// Spam or Archief with mail to review), `tasks` or `outings`.
    public func show(_ place: String) async throws {
        try select(place)
        await selectionLoad?.value
        await messageLoad?.value
    }

    func select(_ place: String) throws {
        let boxes = me?.mailboxes ?? []
        switch place {
        case "tasks": selection = .tasks
        case "outings": selection = .outings
        case "private", "work", "school":
            // The merged inbox per role is gone; older links land on a single inbox.
            guard let box = boxes.first(where: { $0.kind.rawValue == place }) ?? boxes.first else {
                throw ControlError("there is no mailbox")
            }
            selection = .inbox(mailboxId: box.id)
        case "filtered":
            // The Gefilterd page is gone; its review lives in Spam and Archief.
            if let entry = filtered.first(where: { $0.message.folder == .spam }) ?? filtered.first {
                selection = .folder(entry.message.folder, mailboxId: entry.message.mailboxId)
            } else {
                try select("spam")
            }
        default:
            let parts = place.split(separator: ":", maxSplits: 1).map(String.init)
            let wanted = parts.count > 1 ? parts[1] : nil
            let box: MailboxSummary?
            if let wanted {
                box = boxes.first { $0.address == wanted || $0.id == wanted }
            } else {
                box = currentMailboxId.flatMap(mailbox) ?? boxes.first
            }
            switch parts[0] {
            case "inbox", "archive", "sent", "spam", "drafts": break
            default: throw ControlError("unknown place \(place)")
            }
            guard let box else { throw ControlError("no mailbox \(wanted ?? "")") }
            selection = switch parts[0] {
            case "inbox": .inbox(mailboxId: box.id)
            case "drafts": .drafts(mailboxId: box.id)
            default: .folder(MailFolder(rawValue: parts[0])!, mailboxId: box.id)
            }
        }
    }

    /// Prepares a draft (a reply when `replyTo` names a message) and shows it
    /// under Concepten. Sending stays with the person.
    public func prepareDraft(to: String, subject: String, body: String, replyTo: String?) async throws -> [String: Any] {
        guard let api else { throw ControlError("not logged in") }
        let original = replyTo.flatMap { id in messages.first { $0.id == id } }
        if replyTo != nil, original == nil { throw ControlError("message \(replyTo!) is not in the current list") }
        let recipients = Address.parseList(to)
        let mailboxId = original?.mailboxId ?? currentMailboxId ?? me?.mailboxes.first?.id
        guard let mailboxId else { throw ControlError("there is no mailbox to write from") }
        guard !recipients.isEmpty || original != nil else { throw ControlError("give at least one address in to") }
        let draft = try await api.createDraft(
            mailboxId: mailboxId, to: recipients.isEmpty ? [original!.from] : recipients,
            subject: subject.isEmpty ? (original.map { "Re: \($0.subject)" } ?? "") : subject,
            body: body, inReplyTo: original?.id)
        selection = .drafts(mailboxId: mailboxId)
        await selectionLoad?.value
        selectedDraftId = draft.id
        return ["draft": draft.id, "shown": "Concepten"]
    }

    /// Opens a message from the current list.
    public func open(messageId: String) async throws {
        guard messages.contains(where: { $0.id == messageId }) else {
            throw ControlError("message \(messageId) is not in the current list; show its mailbox first")
        }
        selectedMessageId = messageId
        await messageLoad?.value
    }
}

extension Address {
    var formatted: String { Address.format([self]) }
}
