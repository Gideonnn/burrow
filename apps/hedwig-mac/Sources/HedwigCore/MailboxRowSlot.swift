/// The one trailing slot of a mailbox row in the sidebar.
public enum MailboxRowSlot: Equatable, Sendable {
    /// The inbox's unread count; 0 shows nothing.
    case unread(Int)
    /// The folder toggle, pointing down while the mailbox is open.
    case toggle(open: Bool)

    // Selection plays no part: a selected row shows its count like any other.
    public init(unread: Int, hovered: Bool, open: Bool) {
        self = hovered || open ? .toggle(open: open) : .unread(unread)
    }
}
