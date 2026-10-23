import Testing
@testable import HedwigCore

struct MailboxRowSlotTests {
    @Test func aClosedRowShowsItsUnreadCount() {
        #expect(MailboxRowSlot(unread: 4, hovered: false, open: false) == .unread(4))
        #expect(MailboxRowSlot(unread: 0, hovered: false, open: false) == .unread(0))
    }

    @Test func hoverShowsTheClosedToggle() {
        #expect(MailboxRowSlot(unread: 4, hovered: true, open: false) == .toggle(open: false))
    }

    @Test func anOpenMailboxKeepsTheToggleWithoutHover() {
        #expect(MailboxRowSlot(unread: 4, hovered: false, open: true) == .toggle(open: true))
        #expect(MailboxRowSlot(unread: 4, hovered: true, open: true) == .toggle(open: true))
    }
}
