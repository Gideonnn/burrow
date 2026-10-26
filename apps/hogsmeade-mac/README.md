# Hogsmeade for macOS

The playful face of Lumos: the same lists, verdicts, catalogue and keys, as a night with
the proposals fanned out like a hand of cards, stickers and stamps on the posters,
confetti when a title lands on the household's list, and every title as a page in a
scrapbook. Lumos and Hogsmeade run side by side on the same server, so the household can
pick the face it likes. See `.agents/wiki/topics/lumos.md`.

```bash
swift build                          # from this folder
pnpm hogsmeade:install               # build, install in /Applications, start (from the repo root)
./scripts/make-icon.sh               # after changing the icon
```

- The model, the API, the artwork cache, the trailer player, the season menu and the
  control commands come from `apps/lumos-mac` (products `LumosCore` and `LumosUI`); this
  package only holds the face. The state tests live there too.
- Keys are Lumos's: arrows move over the posters, Enter opens the scrapbook, Space shows
  it without moving focus, Esc goes back. `J` list, `N` not now (Enter for no reason), `T`
  trailer, `Z` or ⌘Z undo, ⌘F or `/` search, ⌘1-3 Vanavond, Lijst, Smaak. In the
  scrapbook, left and right go to the previous and next poster.
- Agents: `burrowctl hogsmeade state`, `show`, `search`, `open`, `trailer`, `stop`, `close`.

For a development server with the fixture catalogue (never on Dobby):

```bash
BURROW_DATA_DIR=/tmp/lumos-dev BURROW_SECRET_KEY=… LUMOS_CATALOGUE=fixture pnpm dev:server
LUMOS_SERVER=http://127.0.0.1:4717 LUMOS_KEY=bk_… build/Hogsmeade.app/Contents/MacOS/Hogsmeade
```

Run the bundle (`./scripts/bundle.sh`), not `.build/debug/Hogsmeade`: a bare executable
cannot become the active app, so it never gets key presses.
