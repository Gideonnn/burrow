---
id: 2026-10-22-spam-review-per-mailbox
date: 2026-10-22
kind: decision
area: [hedwig]
topics: [triage]
---

# 2026-10-22 Folders per mailbox, the filter review in Spam, spam stays unread

Gideon reads mail per inbox, so Hedwig's sidebar changed in one evening:

- The merged "Alle privé/werk" view is gone (`SidebarItem.role`); `show private|work|school`
  opens that role's first inbox. The private section is called "Inbox".
- Archief, Verstuurd, Concepten and Spam are per mailbox, under the mailbox row. A small
  chevron shows on hover or for the selected mailbox; the open mailboxes persist in
  `hedwig.sidebar.openMailboxes`. Opening a folder elsewhere opens its mailbox; closing a
  mailbox whose folder is selected selects its inbox.
- The Gefilterd page is gone. Its entries show on top of the mailbox's Spam or Archief
  with the reason, "Klopt" and "Geen spam"/"Terug naar inbox". The count shows on the
  folder and, while closed, on the mailbox row. `/api/filtered` stayed as it was.
- Spam stays unread: triage no longer marks it read, Hedwig does not mark it read on
  opening, the toolbar's Spam button only moves it, and remote images never load in Spam
  (no offer either). "Geen spam" brings it back read, also for older entries that were
  marked read; restored archive mail still comes back unread.

## Rejected

- A collapsible "Meer" holding the shared Archief, Verstuurd and Spam across mailboxes:
  shipped first, replaced the same evening because folders belong to one mailbox.
- `DisclosureGroup` per mailbox: its chevron column is always visible and selecting the
  parent row in an outline was untested. The rows are plain rows under the mailbox.

## Trap

A mailbox with its folders open is several rows from one `ForEach` element, which
`onMove` cannot map back to mailboxes; dragging is off while any mailbox in the section is
open (Omhoog/Omlaag in the menu still work). The sidebar was not checked with real clicks
(the installed Hedwig was running and shares the control socket), so check the chevron
button inside the row and the folder rows' selection on the next install.
