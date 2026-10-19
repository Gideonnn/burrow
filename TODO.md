# TODO

Issue-ready entries, roughly in build order. Delete an entry in the commit that finishes it.

## Finish Dobby (operator)

**What:** enable Tailscale Serve with the link the install prints, put the Google and
Microsoft client ids in the settings on Dobby, and add age recipients for backups. Then
rerun `pnpm server:deploy`.
**Why:** the server runs on Dobby since 2026-10-19 and has an admin key, but the Mac
reaches it only through an SSH tunnel and no real mailbox is connected yet.
**Scope:** about half an hour; see the deploy topic.

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
