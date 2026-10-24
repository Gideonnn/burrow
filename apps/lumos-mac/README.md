# Lumos for macOS

Films and series to choose together: a fixed sidebar, image rows, and the details on
the right with the trailer, scores per source and short reviews. Lists and verdicts live
on the Burrow server; the media stack (Seerr, Radarr, Sonarr, Jellyfin) stays the
backend and Lumos does not request anything yet. See `.agents/wiki/topics/lumos.md`.

```bash
swift build && swift test            # from this folder
pnpm lumos:install                   # build, install in /Applications, start (from the repo root)
./scripts/make-icon.sh               # after changing the icon
```

- Arrows move between cards and rows, Enter opens the details with focus inside, Space
  shows them without moving focus, Esc stops the trailer, then closes the details and
  returns focus to the card. `J` list, `N` not now (Enter for no reason), `T` trailer,
  `Z` or ⌘Z undo, ⌘F or `/` search, ⌘1-3 Ontdekken, Lijst, Smaak.
- Trailers stream only after a click: YouTube in a small web view inside the inspector,
  direct streams in the Mac's own player. Nothing is kept on disk.
- Agents: `burrowctl lumos state`, `show`, `search`, `open`, `trailer`, `stop`, `close`.

For a development server with the fixture catalogue (never on Dobby):

```bash
BURROW_DATA_DIR=/tmp/lumos-dev BURROW_SECRET_KEY=… LUMOS_CATALOGUE=fixture pnpm dev:server
LUMOS_SERVER=http://127.0.0.1:4717 LUMOS_KEY=bk_… build/Lumos.app/Contents/MacOS/Lumos
```

Run the bundle (`./scripts/bundle.sh`), not `.build/debug/Lumos`: a bare executable
cannot become the active app, so it never gets key presses.
