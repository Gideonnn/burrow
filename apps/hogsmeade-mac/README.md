# Hogsmeade for macOS

The household's outings (concerts, plays, festivals, parties) with their tickets, the
one thing still to do, the linked mails and the route on the night. The outings are
Hedwig's: read from ticket mails and kept on the Burrow server; Hogsmeade is the Mac app
for them. Design: `docs/design/outings-app-native.html`. See
`.agents/wiki/topics/hogsmeade.md`.

```bash
swift build && swift test            # from this folder
pnpm hogsmeade:install               # build, install in /Applications, start
./scripts/make-icon.sh               # the icon, after changing it
```

- `HogsmeadeCore` is the outings model (`OutingsModel`), on `HedwigCore` for the outing
  types, the status sentence, the Dutch dates, the place book, the ticket code readers
  and the reminders. `HogsmeadeUI` holds pictures, the map, ticket codes, the menu bar
  and the control commands; `Hogsmeade` the window, the page, the sheets and the
  notifications.
- Keys: `⌘1` Binnenkort, `⌘2` Geweest, `⌘F` search, `⌘N` new, `⌘E` edit the open outing,
  `⌘R` refresh, `⌘[` and Esc back, `⌘V` on a page sets its picture.
- Agents: `burrowctl hogsmeade state`, `show` (upcoming, past), `search`, `open`, `close`.

For a development server:

```bash
BURROW_DATA_DIR=/tmp/lumos-dev BURROW_SECRET_KEY=… pnpm dev:server
HOGSMEADE_SERVER=http://127.0.0.1:4717 HOGSMEADE_KEY=bk_… build/Hogsmeade.app/Contents/MacOS/Hogsmeade
```

Seed outings with `POST /api/outings` (invented titles and places). Run the bundle
(`./scripts/bundle.sh`), not `.build/debug/…`: a bare executable cannot become the
active app, so it never gets key presses or notifications.
