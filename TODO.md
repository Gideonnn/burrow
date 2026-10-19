# TODO

Issue-ready entries, roughly in build order. Delete an entry in the commit that finishes it.

## Finish Dobby (operator)

**What:** enable Tailscale Serve with the link the install prints, put the Google and
Microsoft client ids in the settings on Dobby, and add age recipients for backups. Then
rerun `pnpm server:deploy`.
**Why:** the server runs on Dobby since 2026-10-19 and has an admin key, but the Mac
reaches it only through an SSH tunnel and no real mailbox is connected yet.
**Scope:** about half an hour; see the deploy topic. Serve stays the route for Hedwig and
agents; register the OAuth redirect URIs on the public hostname from the next entry.

## Public access through Cloudflare (operator)

**What:** create the Access application and the tunnel, fill in the Cloudflare settings
and the tunnel token on Dobby, give each person their login address with
`cli.sh set-email`, and rerun the install. The public hostname lives in the settings on
Dobby, not in the repository.
**Why:** a household member without Tailscale must be able to log in from a browser and
connect a mailbox. The server side (tunnel port 4718, Access check) is built.
**Scope:** about an hour; see "Public access" in the deploy topic.

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
