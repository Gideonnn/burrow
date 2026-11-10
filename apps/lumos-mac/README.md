# Lumos for macOS

Films and series to choose together, and what is on Dobby: a sidebar with three pages,
large artwork, and a title page with the trailer, scores per source and short reviews. Lists and verdicts live
on the Burrow server; the media stack (Seerr, Radarr, Sonarr, Jellyfin) stays the
backend and a title on a list is requested there. See `.agents/wiki/topics/lumos.md`.

```bash
swift build && swift test            # from this folder
pnpm lumos:install                   # build, install in /Applications, start (from the repo root)
./scripts/make-icon.sh               # after changing the icon
```

- `LumosCore` is the model, the API and the state machine; `LumosUI` is what the screens
  share on screen: the artwork with its cache, the trailer player, the season menu, the
  menu bar and the control commands. `Lumos` is the app.
- Three pages: Ontdekken (one row of filters; rows without a filter, a grid with one),
  the list, and the Bibliotheek (disk, table, Bezig, delete for admins). Smaak and
  Overgeslagen are in the settings (⌘,). macOS 26 only; standard SwiftUI, the Lumos
  colour as tint.
- Arrows move between cards and rows, Enter opens the title on top, Space shows it
  without moving focus, Esc stops the trailer, then goes one page back. `J` list, `N` not
  now, `T` trailer, `K` watch (where the household stopped), `V` Verras me and ⌫ delete
  are menu shortcuts; `Z` or ⌘Z undo, ⌘F or `/` search (the page you are on), ⌘1
  Ontdekken, ⌘2 the list, ⌘3 Bibliotheek, ⌘4 films, ⌘5 series, ⌥⌘I inspector, ⌘[ back.
- Drag a poster or a table row onto the list in the sidebar.
- A series with more than one season gets a season menu next to the list button; `J`
  takes season 1.
- Trailers stream only after a click: YouTube in a small web view on the title page,
  direct streams in the Mac's own player. Nothing is kept on disk.
- Agents: `burrowctl lumos state`, `show`, `filter`, `search`, `open`, `person`, `back`,
  `trailer`, `stop`, `close`, `watch [screen=<name>|here]`.

For a development server with the fixture catalogue (never on Dobby):

```bash
BURROW_DATA_DIR=/tmp/lumos-dev BURROW_SECRET_KEY=… LUMOS_CATALOGUE=fixture pnpm dev:server
LUMOS_SERVER=http://127.0.0.1:4717 LUMOS_KEY=bk_… build/Lumos.app/Contents/MacOS/Lumos
```

Watching needs `LUMOS_JELLYFIN_URL` and `LUMOS_JELLYFIN_API_KEY` on the server; for a
local run point them at a small fake that answers `/Items`, `/Sessions` and
`/Sessions/:id/Playing`, so no real TV is touched.

`pnpm --filter @burrow/server cli init <name>` makes the first person and key on that
data directory. Run the bundle (`./scripts/bundle.sh`), not `.build/debug/Lumos`: a bare
executable cannot become the active app, so it never gets key presses.
