public enum SidebarItem: Hashable, Sendable {
    case inbox(mailboxId: String)
    /// Archief, Verstuurd or Spam of one mailbox.
    case folder(MailFolder, mailboxId: String)
    /// Concepten of one mailbox: drafts prepared by bots or agents, to review.
    case drafts(mailboxId: String)
    case tasks
    /// Gedeeld: mail shared with or by this person, and Winky's suggestions.
    case shared

    /// The mailbox this place belongs to; the sidebar shows it under that mailbox.
    public var mailboxId: String? {
        switch self {
        case .inbox(let id), .folder(_, let id), .drafts(let id): id
        case .tasks, .shared: nil
        }
    }

    /// The place as text, for @SceneStorage.
    public var storageKey: String {
        switch self {
        case .inbox(let id): "inbox:\(id)"
        case .folder(let folder, let id): "\(folder.rawValue):\(id)"
        case .drafts(let id): "drafts:\(id)"
        case .tasks: "tasks"
        case .shared: "shared"
        }
    }

    public init?(storageKey: String) {
        switch storageKey {
        case "tasks": self = .tasks
        case "shared": self = .shared
        default:
            let parts = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            switch parts[0] {
            case "inbox": self = .inbox(mailboxId: parts[1])
            case "drafts": self = .drafts(mailboxId: parts[1])
            default:
                guard let folder = MailFolder(rawValue: parts[0]), folder != .inbox else { return nil }
                self = .folder(folder, mailboxId: parts[1])
            }
        }
    }
}
