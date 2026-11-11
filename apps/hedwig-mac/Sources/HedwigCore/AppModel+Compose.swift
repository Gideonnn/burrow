import BurrowKit
import Foundation

extension AppModel {
    public func reply(all: Bool = false) -> ComposeDraft? {
        detail.map { reply(to: $0, all: all) }
    }

    public func forward() -> ComposeDraft? {
        detail.map(forward)
    }

    /// A reply or forward from a context menu, also for a message that is not open.
    public func draft(replyingTo id: String, all: Bool = false, forwarding: Bool = false) async -> ComposeDraft? {
        let message: MessageDetail
        if let detail, detail.id == id {
            message = detail
        } else {
            guard let api else { return nil }
            do { message = try await api.message(id: id) } catch {
                report(error)
                return nil
            }
        }
        return forwarding ? forward(message) : reply(to: message, all: all)
    }

    private func reply(to message: MessageDetail, all: Bool) -> ComposeDraft {
        let recipients = (all ? message.replyAll : message.reply) ?? Recipients(to: [message.from], cc: [])
        return ComposeDraft(
            mailboxId: message.mailboxId,
            to: Address.format(recipients.to),
            cc: Address.format(recipients.cc),
            subject: message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)",
            body: "\n\n" + quote(message),
            inReplyTo: message.id)
    }

    private func forward(_ message: MessageDetail) -> ComposeDraft {
        ComposeDraft(
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

    /// Keeps an unsent message under Concepten; a draft it came from gives way to it.
    public func saveDraft(_ draft: ComposeDraft) async throws {
        guard let api else { return }
        _ = try await api.createDraft(
            mailboxId: draft.mailboxId, to: Address.parseList(draft.to), cc: Address.parseList(draft.cc),
            subject: draft.subject, body: draft.body, inReplyTo: draft.inReplyTo)
        if let id = draft.serverDraftId { try? await api.deleteDraft(id) }
        await refreshDrafts()
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
