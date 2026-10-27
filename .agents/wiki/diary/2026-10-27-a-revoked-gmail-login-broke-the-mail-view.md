---
id: 2026-10-27-a-revoked-gmail-login-broke-the-mail-view
date: 2026-10-27
kind: incident
area: [hedwig, server]
topics: [providers]
---

# A revoked Gmail login broke the mail view

Opening mail in Hedwig showed nothing and marking as read failed. Google answered
`invalid_grant` ("Token has been expired or revoked") to every refresh of the Gmail
mailbox's token; the server log held about 900 failing syncs and nobody saw them.

Opening an unread message marks it read first, and that call failing (a 502 from the
provider) aborted the whole open: no detail, an alert with the raw token error. The
message itself was already on the server.

Decided:

- The Mac app opens the message whatever the mark does, and a 409 for a mailbox that
  needs a login shows the notice instead of an alert.
- The server remembers the refusal per mailbox (`reconnect_needed_at`) instead of only
  logging it, skips the mailbox in sync and backfill (no more log flood), and lets the
  owner log in again without an admin key. The callback checks the address, so logging
  in with the wrong Google account cannot silently add a second mailbox.

Rejected: keeping the state in memory (lost on restart, and the next refusal could be a
day away for a quiet mailbox); clearing the mark on any successful refresh (only a new
login can fix `invalid_grant`, so the callback is the one place to clear it).

If this recurs within days, check that the Google OAuth app is published, not in
*Testing* (see [providers](../topics/providers.md)).
