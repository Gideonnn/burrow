# Hedwig for macOS

The native mail client for Burrow, in SwiftUI. It talks to the Burrow server with one
API key and shows only that key's mailboxes.

```bash
swift build && swift test            # from this folder
./scripts/bundle.sh                  # build/Hedwig.app
./scripts/install.sh                  # install in /Applications for Spotlight and Raycast
./scripts/make-icon.sh               # after changing Resources/AppIcon.svg
pnpm hedwig:release                  # from the repo root: publish to every Mac (signed)
```

Open it from Raycast by adding the alias `email` to Hedwig in Raycast's settings.

## Trying it against a demo server

```bash
cd apps/server
export BURROW_DATA_DIR=/tmp/burrow-demo BURROW_SECRET_KEY="$(pnpm -s cli generate-secret)"
pnpm -s cli seed-demo          # prints the demo keys
pnpm dev                       # http://127.0.0.1:4717
```

Then connect Hedwig to `http://127.0.0.1:4717` with the "MacBook Gideon" key. For
screenshots without the Keychain, start the binary with `HEDWIG_SERVER`, `HEDWIG_KEY`
and optionally `HEDWIG_OPEN` with any place `burrowctl hedwig show` takes (`filtered`, `drafts`,
`outings`, `archive`, an address).

## What it does

- The sidebar's "Inbox" lists every mailbox; each opens (a small chevron on hover, or its
  menu) to its own Archief, Verstuurd, Concepten and Spam. Reading shows HTML without
  JavaScript or remote content (trackers stay blocked) under a header laid out like
  Mail's (sender, subject, Aan/Kopie/Antwoord aan) that scrolls with the message;
  replying, forwarding.
- Archive, delete, spam, read and flag act at the provider, so phones see the same.
- What the bot filtered waits for review in that mailbox's Spam or Archief, on top and
  with its reason: "Klopt" confirms, "Geen spam" or "Terug naar inbox" restores. A count
  on Spam or Archief shows what still waits; the mailbox row shows only its unread
  inbox count from the server (all mail, not the loaded page), which the folder chevron
  replaces on hover or while the folders show. The list header counts the whole folder
  the same way.
- Spam stays unread and never loads remote images, not even on request, until you say
  "Geen spam"; then it goes back to the inbox as read.
- "Evenementen": the household's outings, each with one status sentence; Details holds
  times, tickets per person, mails and search words. Drop a pdf, Wallet pass or
  screenshot on an outing to keep it as a ticket. Each outing shows a picture from its mail or
  website; paste (⌘V) or drop another on the top of the page. Until Patronus exists, the Mac
  reminds of the day and of deadlines with notifications (see the
  [outings topic](../../.agents/wiki/topics/outings.md)).
- "Concepten" (per mailbox): drafts prepared by bots or agents through MCP, to review and send.
- "Taken": what routines propose, to approve or reject. Tasks meant for this Mac run in
  `burrowctl runner` (see the [agent-control topic](../../.agents/wiki/topics/agent-control.md)),
  also while Hedwig is closed; Settings › Agent and Settings › Runners show and pause it.
- Messages show their category, the summary and a lock for sensitive mail once the
  server has facts for them; search hides login codes unless "Toon ook codes" is on.
- The dot at the bottom of the sidebar turns orange while the server cannot be reached
  (a deploy, the tunnel); Hedwig retries by itself and reloads once it is back.
- Settings: the bot instructions and learned rules, adding accounts (admin keys), the
  household (everyone's features and devices, for admins) and the workers.

## Letting an agent operate Hedwig

While Hedwig runs, `burrowctl hedwig …` (or the older `hedwigctl …`, both installed in
`~/.local/bin`) reads and operates it, and `burrowctl mcp` offers the same as MCP tools:

```bash
burrowctl hedwig state                  # mailboxes, the message list and the open message
burrowctl hedwig show inbox:you@example.com
burrowctl hedwig open <messageId>
burrowctl hedwig draft to=a@example.com subject=Hoi body="Tot morgen"   # shown under Concepten
burrowctl hedwig find Archiveer         # elements by label; then press, type or select an id
```

Password and key fields cannot be read or typed into. Pressing Verstuur or Verwijder
opens a dialog in Hedwig: nothing is sent or deleted until you allow it, and the agent
cannot see or press that dialog. See `.agents/wiki/topics/agent-control.md`.

## Updates

`pnpm hedwig:install` tries a change on this Mac only; `pnpm hedwig:release` publishes
a signed build that every Hedwig offers as "Update klaar · Herstart". See
`.agents/wiki/topics/app-updates.md`.
