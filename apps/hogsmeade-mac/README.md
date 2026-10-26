# Hogsmeade for macOS

The household's outings (concerts, plays, festivals, parties) with their tickets, the
one thing still to do, and the route on the night. The outings are Hedwig's: read from
ticket mails and kept on the Burrow server; Hogsmeade is a window on them. Two faces
from one package, so the household can run both and pick the one it likes:

- **Hogsmeade** (`--product Hogsmeade`): the native face, `docs/design/outings-app-native.html`.
  A sidebar that narrows, the poster wall with tonight on top, a page per outing.
- **Hogsmeade Feest** (`--product HogsmeadeFeest`): the playful face, `docs/design/hogsmeade-style.html`.
  A night with the posters as a hand of cards, the day itself as a party with confetti
  and a clock, and every outing as a page in a scrapbook.

See `.agents/wiki/topics/hogsmeade.md`.

```bash
swift build && swift test            # from this folder
pnpm hogsmeade:install               # the native face: build, install in /Applications, start
pnpm hogsmeade:install:feest         # the playful face
./scripts/make-icon.sh               # both icons, after changing them
```

- `HogsmeadeCore` is the outings model (`OutingsModel`), on `HedwigCore` for the outing
  types, the status sentence, the Dutch dates, the place book and the ticket code
  readers. `HogsmeadeUI` is what both faces share on screen: pictures, the map, ticket
  codes, confetti, the menu bar and the control commands. The faces only hold views.
- Keys: `⌘1` Binnenkort, `⌘2` Geweest, `⌘F` search, `⌘N` new, `⌘R` refresh, Esc back.
  In the playful face, Enter opens the first poster.
- Each face has its own login, Keychain item and update channel (`hogsmeade`,
  `hogsmeade-feest`), so both run side by side.
- Agents: `burrowctl hogsmeade state`, `show` (upcoming, past, wall, tonight), `search`,
  `open`, `close`; the same with `hogsmeade-feest`.

For a development server:

```bash
BURROW_DATA_DIR=/tmp/lumos-dev BURROW_SECRET_KEY=… pnpm dev:server
HOGSMEADE_SERVER=http://127.0.0.1:4717 HOGSMEADE_KEY=bk_… build/Hogsmeade.app/Contents/MacOS/Hogsmeade
```

Seed outings with `POST /api/outings` (invented titles and places). Run the bundle
(`./scripts/bundle.sh [HogsmeadeFeest]`), not `.build/debug/…`: a bare executable
cannot become the active app, so it never gets key presses.
