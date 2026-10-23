---
id: 2026-10-23-hedwig-list-filter-on-the-server
date: 2026-10-23
kind: decision
area: [hedwig, server, contracts]
topics: []
---

# Mail's list filter in Hedwig, filtered on the server

Gideon wanted Apple Mail's filter button above the list. A click turns it on, the chevron
menu picks the criteria (Ongelezen by default, Antwoord nodig, Met bijlagen, Aan mij, Van
vandaag), and a message must match all of them, as in Mail. The criteria persist in
UserDefaults; the filter itself starts off on every launch.

## Decided

- **The server filters** (`filter=unread,attachments` and `since` on
  `GET /mailboxes/:id/messages`, `messageListQuery` in contracts), so the list holds
  every match in the folder, not just the matches in the newest 100.
- **"Van vandaag" goes as `since`**, because only the Mac knows where its day starts.
- **"Aan mij" means the mailbox address is in To.** Cc mij was left out: the summary
  carries no Cc, so the Mac could not tell whether a changed message still matches.
- Read mail stays in a filtered list until the selection moves on; live reloads put it
  back at its old place.

Trap: several Swift tests set `selection` (which starts a load) and then called
`loadSelection()` again. The two loads raced and one test failed about one run in five;
the tests now wait for `selectionLoad` instead.
