# Lumos

Lumos helps the household choose films and series to watch together: a native Mac app
with image rows and an inspector, and a module on the server with a catalogue provider,
the household's list, each person's own list, and verdicts that can always be undone.
The media stack (Seerr, Radarr, Sonarr, Jellyfin) stays the backend: a title put on a list
is requested from Seerr, which hands it to Radarr or Sonarr; Lumos plays nothing yet. Plan and phases: `docs/plans/2026-10-25-lumos.md`. Code:
`modules/lumos`, `packages/contracts/src/lumos.ts`, `apps/lumos-mac`.

## The catalogue

A `CatalogueProvider` (`modules/lumos/src/catalogue.ts`) gives candidates, details,
search (title, maker, cast, genre, trait, year) and a maker's titles. Titles are keyed by
`(mediaType, tmdbId)`: film and series ids collide. Without a provider every catalogue
route answers 503 "Lumos is niet gekoppeld aan een catalogus"; lists still answer.

**Seerr** (`seerr.ts`, `SeerrCatalogue`) is the real one, on when `LUMOS_SEERR_URL` and
`LUMOS_SEERR_API_KEY` are both set (on Dobby they are, in the server settings; the media
stack's admin route copied the key from its root-only secrets). Seerr serves TMDB's data,
so no TMDB key is needed:

- the pool: trending (two pages), popular films and series, and the 40 titles the media
  server added last (`/media?filter=available`), cached ten minutes; details five
  minutes. While Seerr is down the last data is served; without any, routes answer 503.
- artwork as `image.tmdb.org` URLs; trailers from `relatedVideos` (YouTube, "Trailer"
  before "Teaser"); scores from `ratingscombined` (IMDb, RT critics and audience) and
  TMDB's vote average with its count. Synopses are English (`language=en`).
- availability from Seerr's media status; "downloading" only with a live download status
  (Seerr's `PROCESSING` alone proves nothing), with progress in the details.
- every answer is mapped field by field; a test feeds the key and user records through
  every Seerr answer and checks no Lumos answer carries them.

`FixtureCatalogue` (`fixtures.ts`) is for development, switched on with
`LUMOS_CATALOGUE=fixture`. It is fenced off:

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
`DELETE verdicts/:id`, `changes/:id/undo`, `requests/…/retry`. MCP: `search_titles` and `list_watchlist`,
read only. Setting: `lumos.enabled`.

## Requests

`lumos_requests` is an outbox: putting a live title on any list writes its row in the same
transaction (one row per title, so two people or two lists ask once).
`LumosRequests` (`requests.ts`) sends it 15 seconds later, so undo stops it; at sending it
checks the title is still on a list (else `dropped`) and whether Seerr already knows it
(`exists`, nothing asked), then `POST /request` with Seerr's own defaults (no `is4k`,
which is a separate 4K server). Failures retry with backoff for eight attempts, then
`failed` with "Opnieuw proberen" (`POST /api/lumos/requests/:mediaType/:tmdbId/retry`). A
sent request is never cancelled; removing a title leaves Seerr alone. Series ask the
chosen seasons, season 1 when none was chosen. The fixtures never request.

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

A season picker, playback in Jellyfin (phase 5), history import (6), curated snippets and
taste ranking (7): see the plan and `TODO.md`.
