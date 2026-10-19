# TODO

Issue-ready entries, roughly in build order. Delete an entry in the commit that finishes it.

## Finish Dobby (operator)

**What:** connect the real mailboxes (Fastmail with an API token; Gmail and Microsoft
after their client ids are in the settings on Dobby, redirect URI
`<BURROW_PUBLIC_URL>/oauth/callback`), and add age recipients for backups.
**Why:** Burrow is reachable through Cloudflare since 2026-10-19 and Hedwig connects,
but no real mailbox is connected and backups are unencrypted copies on Dobby itself.
**Scope:** under an hour; see the providers and deploy topics.

## Household profiles: the rest

**What:** a signature per mailbox and a default sender per role; decide whether an admin
may create keys for another person's mailboxes, or only with that person's consent.
**Why:** Gideon and Angela each have private and work or school mail, and the admin can
now technically read everyone's mail.
**Scope:** server columns and routes plus Hedwig settings; half a day.

## Web interface

**What:** a web app served by the server for settings: people, mailboxes (connect and
remove), API keys, bots and routines. Logged in through Access: the tunnel check in
`auth/cloudflareAccess.ts` already resolves the person and can pass them on to the
routes. Give it a name from the naming topic.
**Why:** settings now need the CLI or the Mac app; a browser works for everyone in the
household on any device.
**Scope:** clickable design in `docs/design/` first, then build.

## Invoice routine

**What:** a skill that reads an invoice (fields, PDF attachment), files it and proposes a
line for the bookkeeping, run as a client routine with a server fallback. Needs
attachment download in the providers and a decision about the bookkeeping package.
**Why:** chosen by Gideon as the first household routine; deferred on purpose.
**Scope:** design note first.

## Licence

**What:** choose a licence for the public repository (MIT, or AGPL to keep hosted
forks open) and add `LICENSE`.
**Why:** without one, nobody may legally reuse the code, which defeats publishing it.
**Scope:** one file; Gideon decides.
