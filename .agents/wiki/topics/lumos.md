# Lumos

Lumos helps the household choose films and series to watch together: a native Mac app
with image rows and an inspector, and a module on the server with a catalogue provider,
the household's list, each person's own list, and verdicts that can always be undone.
The media stack (Seerr, Radarr, Sonarr, Jellyfin) stays the backend; Lumos requests and
plays nothing yet. Plan and phases: `docs/plans/2026-10-25-lumos.md`. Code:
`modules/lumos`, `packages/contracts/src/lumos.ts`, `apps/lumos-mac`.

## The catalogue

A `CatalogueProvider` (`modules/lumos/src/catalogue.ts`) gives candidates, details,
search (title, maker, cast, genre, trait, year) and a maker's titles. Titles are keyed by
`(mediaType, tmdbId)`: film and series ids collide. Without a provider every catalogue
route answers 503 "Lumos is niet gekoppeld aan een catalogus"; lists still answer.

The only provider yet is `FixtureCatalogue` (`fixtures.ts`), switched on with
`LUMOS_CATALOGUE=fixture` for development. It is fenced off:

- every catalogue answer carries `dataOrigin: 'fixture'` and the Mac shows a
  "Testgegevens" badge in the toolbar and the sidebar;
- `loadConfig` refuses it next to `LUMOS_SEERR_URL`, behind Cloudflare Access, or with a
  public `BURROW_PUBLIC_URL`, so it never runs on Dobby;
- list items and verdicts store their `origin`; only rows of the active origin are read,
  so fixture entries never show up next to the real catalogue;
- fixture ids start at 9,000,001, never TMDB ids; there is no artwork (the Mac draws a
  tile in the title's colours); invented titles carry scores marked "(test)".

Three fixture titles are real because their trailers were checked on 24 October 2026:
Palm Springs and The Holdovers (YouTube) and Sintel (a CC BY 3.0 MP4 of the Blender
Foundation). Their scores and quotes are dated snapshots with a source; The Holdovers has
no score, so it shows none.

## Lists, verdicts and undo

- `lumos_list_items`: a title on the household's list (no owner) or a person's. Shared
  and personal rows have separate partial unique indexes: SQLite treats NULL owners as
  distinct, so one index over the owner lets the shared list hold a title twice.
- `lumos_verdicts`: `not-now` (optional reason), `seen`, `more-like-this`,
  `less-like-this`, for the household or one person. A pass (not now, seen) takes the
  title off that scope's list and out of its proposals; "seen" never weighs similar
  titles down, "less like this" does. Search ignores verdicts.
- `lumos_changes`: every change records what it added, removed and undid, and answers
  with its `changeId`; `POST /api/lumos/changes/:id/undo` reverses exactly that, for its
  author only, once. Nothing is deleted; undoing sets `removedAt` or `undoneAt` back.
- A personal list and personal verdicts are their person's; there is no route that names
  someone else's. The household's are everyone's, like [outings](outings.md). Changes emit
  `lumos.changed` with the scope, to both Macs or only the owner.

Routes (all under `/api/lumos`, `read` to look, `organize` to change): `status`, `rows`,
`titles`, `search`, `titles/:mediaType/:tmdbId`, `similar/…`, `credits/:id`,
`lists/:scope` with `PUT`/`DELETE …/items/:mediaType/:tmdbId`, `verdicts`,
`DELETE verdicts/:id`, `changes/:id/undo`. MCP: `search_titles` and `list_watchlist`,
read only. Setting: `lumos.enabled`.

## On the Mac

`LumosCore/LumosModel.swift` is the state machine: the page, the cursor over rows and
grids (`Navigation.swift`, up and down find the remembered or nearest card), the
inspector and the card focus returns to, the "Niet nu" menu's choice, the trailer and the
undo stack. The views only forward keys; the tests drive the model like the keyboard.

- Scope: Samen or your own name. "Yes" (`J`) goes to the current scope's list.
- In Samen, "Op jouw lijst, nog niet samen" shows only your own entries.
- The mood chips narrow Ontdekken by genre and trait; nothing filters on runtime.
- Trailers (`TrailerPlayer.swift`) exist only after a click: YouTube through its IFrame
  API in a `WKWebView` whose base URL is the Burrow server (YouTube refuses embeds without
  an origin), direct streams in `AVPlayerView`. The status line says "Speelt af" only on
  the player's own event, else "Speler geladen". Esc, closing and another title tear the
  view down, which stops the sound.
- `burrowctl lumos state`, `show`, `search`, `open`, `trailer`, `stop`, `close`. The list
  buttons are marked `lumos.approve.list`, because a list entry will request media later.

Run the bundle (`apps/lumos-mac/scripts/bundle.sh`), not `.build/debug/Lumos`: a bare
executable has activation policy "prohibited", never becomes the active app and gets no
key presses. `LUMOS_SERVER` and `LUMOS_KEY` connect without the Keychain.

## Not yet

Seerr and TMDB (phase 3), requests (4), playback (5), history import (6), curated
snippets and taste ranking (7): see the plan.
