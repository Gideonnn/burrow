---
id: 2026-11-11-hedwig-becomes-a-native-mail-client
date: 2026-11-11
kind: decision
area: [hedwig]
topics: [outings, hogsmeade, search]
---

# Hedwig becomes a native mail client only

A HIG audit of Hedwig, then a change of scope: Evenementen moved to Hogsmeade.

**Outings out.** The page, the mail card and the map, ticket and picture views left the
Hedwig target. The outing code stays in HedwigCore because Hogsmeade imports it (moving it
is a `TODO.md` entry). The reminders (`OutingNotifications`) stayed in Hedwig: Hogsmeade
has none yet, and dropping them would silently lose the ticket deadlines. So `AppModel`
got two switches: `followsOutings` (fetch the list at start and on `outing.changed`; Hedwig
sets it for the reminders) and `showsOutingCards` (ask the server about every opened mail;
nobody sets it now). `NSLocationUsageDescription` left the bundle with the map.

**Selection.** `selectedMessageIds` is the list's set; `selectedMessageId` stays public as
"the open message" (one selected, else nil), since burrowctl, Gedeeld, the answer card and
tests set it. Several selected open nothing and mark nothing read. The server applies ops
to one message per call, so a selection is a call each and the first failure stops the
rest; a batch route was out of scope (no server changes). Reply and forward take one
message; a context menu on a message that is not open fetches it without marking it read.

**Traps.**
- `.searchScopes` behind an `if` in a modifier rebuilt the whole split view whenever the
  place changed; it is now always applied, with only "Overal" where there is no place.
- SwiftUI cannot veto closing a window. Compose's "Concept bewaren?" stands in as the
  window's delegate and forwards everything else to SwiftUI's (`CloseGuard`).
- A file kept in the temporary folder survives test runs; the attachment test uses a fresh
  message id.
- Editing a source file while `bundle.sh` runs fails the release build with "modified
  during the build", hidden by `| tail`.

**Attachments** use the server's existing `GET /messages/:id/attachments` routes: Quick Look
on a click, a `Transferable` that fetches on drop or share, Bewaar in Downloads.
