# Hedwig for macOS

The native mail client for Burrow, in SwiftUI. It talks to the Burrow server with one
API key and shows only that key's mailboxes.

```bash
swift build && swift test            # from this folder
./scripts/bundle.sh                  # build/Hedwig.app
./scripts/bundle.sh --install        # also copy to ~/Applications
./scripts/make-icon.sh               # after changing Resources/AppIcon.svg
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
and optionally `HEDWIG_OPEN=filtered|drafts|archive`.

## What it does

- Per-account inboxes, the shared Sent, Archive and Spam lists, reading with HTML shown
  without JavaScript or remote content (trackers stay blocked), replying, forwarding.
- Archive, delete, spam, read and flag act at the provider, so phones see the same.
- "Gefilterd": what the bot filtered, with its reason; confirm or restore.
- "Concepten": drafts prepared by bots or agents through MCP, to review and send.
- "Taken": what routines propose, to approve or reject. While Hedwig runs (also with
  every window closed) it claims tasks meant for this Mac and runs them with the local
  `claude`; switch it off or set the path under Settings › Agent.
- Settings: the bot instructions and learned rules, adding accounts (admin keys).
