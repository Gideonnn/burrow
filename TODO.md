# TODO

Issue-ready entries, roughly in build order. Delete an entry in the commit that finishes it.

## Finish Dobby (operator)

**What:** set up Cloudflare as in the deploy topic (Access applications, `/api` bypass,
rate limit, tunnel, SSH hostname), fill in the settings and tunnel token on Dobby, give
each person their login address with `cli.sh set-email`, put the Google and Microsoft
client ids in the settings, add age recipients for backups, then rerun
`pnpm server:deploy`. Point Hedwig at the public hostname. Remove Tailscale only once
SSH through the tunnel works. The public hostname lives in the settings on Dobby, not
in the repository.
**Why:** the server runs on Dobby since 2026-10-19 with an admin key, but is reachable
only over SSH and no real mailbox is connected yet.
**Scope:** about an hour and a half; see the deploy topic.

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
