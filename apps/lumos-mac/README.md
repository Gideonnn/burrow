# Lumos for macOS

Films and series to choose together: a fixed sidebar, image rows, and the details on
the right with the trailer, scores per source and short reviews. Lists and verdicts live
on the Burrow server; the media stack (Seerr, Radarr, Sonarr, Jellyfin) stays the
backend and a title on a list is requested there. See `.agents/wiki/topics/lumos.md`.
Hogsmeade (`apps/hogsmeade-mac`) is the playful face on the same model and lists.

```bash
swift build && swift test            # from this folder
pnpm lumos:install                   # build, install in /Applications, start (from the repo root)
./scripts/make-icon.sh               # after changing the icon
```

- `LumosCore` is the model, the API and the state machine; `LumosUI` is what both faces
  share on screen: the artwork with its cache, the trailer player, the season menu, the
  menu bar and the control commands. `Lumos` is the native face.
- Arrows move between cards and rows, Enter opens the details with focus inside, Space
  shows them without moving focus, Esc stops the trailer, then closes the details and
  returns focus to the card. `J` list, `N` not now (Enter for no reason), `T` trailer,
  `Z` or ⌘Z undo, ⌘F or `/` search, ⌘1-3 Ontdekken, Lijst, Smaak.
- A series with more than one season gets a season menu next to "Op onze lijst zetten";
  `J` takes season 1.
- Trailers stream only after a click: YouTube in a small web view inside the inspector,
  direct streams in the Mac's own player. Nothing is kept on disk.
- Agents: `burrowctl lumos state`, `show`, `search`, `open`, `trailer`, `stop`, `close`.

For a development server with the fixture catalogue (never on Dobby):

```bash
BURROW_DATA_DIR=/tmp/lumos-dev BURROW_SECRET_KEY=… LUMOS_CATALOGUE=fixture pnpm dev:server
LUMOS_SERVER=http://127.0.0.1:4717 LUMOS_KEY=bk_… build/Lumos.app/Contents/MacOS/Lumos
```

`pnpm --filter @burrow/server cli init <name>` makes the first person and key on that
data directory. Run the bundle (`./scripts/bundle.sh`), not `.build/debug/Lumos`: a bare
executable cannot become the active app, so it never gets key presses.
