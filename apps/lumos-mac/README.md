# Lumos for macOS

Films and series to choose together: a fixed sidebar, image rows, and the details on
the right with the trailer, scores per source and short reviews. Lists and verdicts live
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
- Arrows move between cards and rows, Enter opens the title as a page over the rows,
  Space shows it without moving focus, Esc stops the trailer, then goes one page back
  (a person, "Meer zoals dit" and a person's work stack) and returns focus to the card.
  `J` list, `N` not now (Enter for no reason), `T` trailer, `Z` or ⌘Z undo, ⌘F or `/`
  search, ⌘1 Ontdekken, ⌘2 Zoeker, ⌘3 Lijst, ⌘4 Films, ⌘5 Series, ⌘[ back.
- Films and Series are the shop's shelves: sort chips, a genre, a decade, Nederlands,
  and the next page while scrolling. The Zoeker is for wandering; "Verras me" reshuffles.
- Details are kept once loaded and fetched ahead for the card under the cursor or the
  mouse, so a page opens at once; a face opens the person's page with everything they made.
- A series with more than one season gets a season menu next to "Op onze lijst zetten";
  `J` takes season 1.
- An available title gets a "Kijken" row: "Op <tv>" starts it on the screen where the
  Jellyfin app is open, "Hier" opens its page in the browser. `K` (⌘K) takes the only
  screen, the page when none is open, and asks when several are; ⇧⌘K is the page.
- Trailers stream only after a click: YouTube in a small web view inside the inspector,
  direct streams in the Mac's own player. Nothing is kept on disk.
- Agents: `burrowctl lumos state`, `show`, `search`, `open`, `person`, `back`, `trailer`,
  `stop`, `close`, `watch [screen=<name>|here]`.

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
