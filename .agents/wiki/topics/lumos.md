# Lumos

Lumos helps the household choose films and series to watch together: a native Mac app
with image rows and an inspector, and a module on the server with a catalogue provider,
the household's list, each person's own list, and verdicts that can always be undone.
The media stack (Seerr, Radarr,
Sonarr, Jellyfin) stays the backend: a title put on a list is requested from Seerr,
which hands it to Radarr or Sonarr, and an available title is opened in Jellyfin's web
app or started on the TV through Jellyfin's sessions. Plan and phases:
`docs/plans/2026-10-25-lumos.md`. Code: `modules/lumos`, `packages/contracts/src/lumos.ts`,
`apps/lumos-mac`.

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
- artwork as `image.tmdb.org` URLs (posters `w342`, stills `w780`, the inspector's
  `w1280`); trailers from `relatedVideos` (YouTube, "Trailer" before "Teaser"); scores
  from `ratingscombined` (IMDb, RT critics and audience) and TMDB's vote average with its
  count. Synopses are English (`language=en`).
- availability from Seerr's media status; "downloading" only with a live download status
  (Seerr's `PROCESSING` alone proves nothing), with progress in the details.
- every answer is mapped field by field; a test feeds the key and user records through
  every Seerr answer and checks no Lumos answer carries them.

`FixtureCatalogue` (`fixtures.ts`) is for development, switched on with
`LUMOS_CATALOGUE=fixture`. It is fenced off:

- every catalogue answer carries `dataOrigin: 'fixture'` and both Macs show a
  "Testgegevens" badge;
- `loadConfig` refuses it next to `LUMOS_SEERR_URL`, behind Cloudflare Access, or with a
  public `BURROW_PUBLIC_URL`, so it never runs on Dobby;
- list items and verdicts store their `origin`; only rows of the active origin are read,
  so fixture entries never show up next to the real catalogue;
- fixture ids start at 9,000,001, never TMDB ids; there is no artwork (the Macs draw a
  tile in the title's colours); invented titles carry scores marked "(test)".

Three fixture titles are real because their trailers were checked on 24 October 2026:
Palm Springs and The Holdovers (YouTube) and Sintel (a CC BY 3.0 MP4 of the Blender
Foundation). Their scores and quotes are dated snapshots with a source; The Holdovers has
no score, so it shows none.

**Browsing, related titles and people.** `browse` asks Seerr's discover with TMDB's
sorts and filters (`sortBy`, `genre`, the original `language`, a date span for a decade
or a year, vote floors for "top" and "gems"; "upcoming" is the discover from today on,
"trending" the trending page narrowed to the kind), one page at a time, cached ten
minutes with the genre list (fetched in Dutch). `related` is TMDB's recommendations
followed by its similar titles, each once. `person` is `/person/:id` plus the combined
credits: every title once, the most popular first, with the part ("als Nyles", "Regie,
Scenario"). Details carry the tagline, status, release and last air dates, budget and
revenue (null when the source has none, never zero), studios or networks, the collection,
the cast with parts and photos (`w185`), the makers (directors, writers, creators, one
line per person) and a series' seasons and episode count. The original language shows
as a Dutch word (`Intl.DisplayNames`). The fixtures sort and filter in memory, twelve to
a page, and name their credits as cast and crew. The Zoeker (`explore`) builds rows
from the scope's "more like this" titles and two titles from its list (through
`related`), trending, the year's best, best series, Dutch films, hidden gems, a decade
and a surprise page; the seed picks the decade and the page, so "Verras me" is a new
seed and the same seed is the same page.

`turbo.json` passes `LUMOS_*` through to `pnpm dev:server` (next to `BURROW_*`); without
that line the fixture flag never reached the server and the dev loop silently ran
without a catalogue.

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
  `lumos.changed` with the scope, to every Mac of the scope, so the two people's Macs
  follow each other.

Routes (all under `/api/lumos`, `read` to look, `organize` to change): `status`, `rows`,
`titles`, `search`, `titles/:mediaType/:tmdbId`, `similar/…`, `credits/:id`,
`lists/:scope` with `PUT`/`DELETE …/items/:mediaType/:tmdbId` (the PUT body may carry
`seasons`), `verdicts`, `DELETE verdicts/:id`, `changes/:id/undo`, `requests/…/retry`,
`watch/:mediaType/:tmdbId` and `POST watch/…/screen` (body `deviceId`).
MCP: `search_titles` and `list_watchlist`, read only. Setting: `lumos.enabled`. The
module lists `lumos` as its client, so the server offers it updates.

## Requests

`lumos_requests` is an outbox: putting a live title on any list writes its row in the same
transaction (one row per title, so two people or two lists ask once).
`LumosRequests` (`requests.ts`) sends it 15 seconds later, so undo stops it; at sending it
checks the title is still on a list (else `dropped`) and whether Seerr already knows it
(`exists`, nothing asked), then `POST /request` with Seerr's own defaults (no `is4k`,
which is a separate 4K server). Failures retry with backoff for eight attempts, then
`failed` with "Opnieuw proberen" (`POST /api/lumos/requests/:mediaType/:tmdbId/retry`). A
sent request is never cancelled; removing a title leaves Seerr alone. Series ask the
seasons chosen in the season menu, season 1 when none was chosen (and always with `J`).
The fixtures never request.

## Watching

`JellyfinPlayer` (`jellyfin.ts`) is on when `LUMOS_JELLYFIN_URL` and
`LUMOS_JELLYFIN_API_KEY` are set (`LUMOS_JELLYFIN_WEB_URL` when browsers in the house
reach Jellyfin at another address). `status.watch` tells the Macs. The key is Jellyfin's
service key from the media stack's root-only secrets; the operator's `tv` repository
has `media/host/connect-lumos-jellyfin.sh`, run through `root-run.sh`, which copies it
into the server settings without showing it, like the Seerr one. The library is only
read: no deletes, no marks, no user data.

- `GET watch/:ref` answers the title's page in Jellyfin's web app (`web`, null when the
  library does not have it: the catalogue's "available" is not taken on trust), the
  episode a screen would start, and the **screens**: sessions with `SupportsRemoteControl`,
  mostly the TV with the Jellyfin app open, by device id, name and what they play.
- `POST watch/:ref/screen` starts the title on the screen with that device id
  (`/Sessions/{id}/Playing?playCommand=PlayNow`), then asks the sessions up to six times
  whether `NowPlayingItem` is the title: `confirmed` is the screen's own word, else the
  Mac says "gestart; de tv meldt nog niets". A series starts at NextUp for the screen's
  user, else its first episode. No session on that device answers 409; Jellyfin down 503.
  The first session found is never taken: the Mac picks by device id, or asks when
  several screens are open.
- The item is found by the id Seerr knows (`mediaInfo.jellyfinMediaId`, kept as
  `mediaServerId` on the catalogue title) through `GET /Items?ids=`, else by name with a
  matching `ProviderIds.Tmdb`. Not `GET /Items/{id}`: Jellyfin 12 answers 400 to that
  (and to `/Shows/NextUp`) without a `userId`; the query forms work with a service key.
- Waking the TV and opening the app are not done: without a session the button says
  "Open Jellyfin op de tv".

## On the Mac

`apps/lumos-mac` is a package with three targets; the first two are library products, so
another face or tool can build on them:

- `LumosCore`: `LumosModel.swift` is the state machine: the page, the cursor over rows
  and grids (`Navigation.swift`, up and down find the remembered or nearest card), the
  pages over the rows (`stack`: a title or a person, Esc goes back one), the card focus
  returns to, the "Niet nu" menu's choice, the trailer, the undo stack and `lastChange`.
  The views only forward keys; the tests drive the model like the keyboard.
- `LumosUI`: what the screens share. `ImageLoader` downloads a picture once
  (URLCache on disk under `Caches/Burrow/images`), decodes it once at the size it is
  shown (`CGImageSourceCreateThumbnailAtIndex`, off the main thread) and keeps it in
  memory; `CachedImage` starts with what is cached so nothing flashes, and the rows
  prefetch their artwork. SwiftUI's `AsyncImage` kept nothing between views, which made
  rows flicker and stutter. Also here: `Artwork` with the placeholder tile, the trailer
  player, `SeasonMenu`, the menu bar commands, the settings view and the control
  commands.
- `Lumos`: the app itself.

What the model does for speed: the page and the sidebar counts load at the same time,
details and similar titles too, and Ontdekken's last rows are kept on disk
(`Application Support/<App>/Cache/rows-<scope>.json`) so the window opens full before
the server answers. Details are kept in memory once loaded (80 titles, five minutes, and
cleared by any list or verdict change, since those change what a detail says); the cursor
and the mouse fill that cache before Enter or a click (`prefetch`, 150 ms after the
cursor settles), and a prefetched title's artwork is warmed too, so a page opens with no
wait and the next one is already there. Going back shows the rows exactly as left.

The pages, in the sidebar's order:

- **Ontdekken**: the rows from `/rows`, the mood chips narrowing by genre and trait
  (the genres come from Seerr in Dutch, so "Komedie" matches).
- **Zoeker**: `/explore` rows to wander through, and "Verras me" for a new seed.
- **Onze lijst** / **Jouw lijst**.
- **Films** and **Series**: the shop's shelves from `/browse`, with chips for the sort
  (Populair, Nieuw, Binnenkort, Best beoordeeld, Trending, Verborgen parels), a genre
  menu, a decade menu and "Nederlands"; the next page loads while scrolling and when the
  keyboard reaches the last lines. Taste never sorts a shelf.
- **Klaar in Jellyfin**, **Smaak**, **Overgeslagen** as before.

A title opens as a page over the rows (`TitlePage.swift`), not in a drawer: the still
across the top, the trailer or the stills beside the facts and the actions, then scores
per source, Productie (budget and revenue with the ratio, studio, collection, dates),
the cast and makers as faces with their parts, a series' seasons, "Meer zoals dit"
(TMDB's recommendations and similar titles) and the reviews. A face, a name in the
search chips, opens the person's page (`PersonPage.swift`): photo, department, birth,
biography, and their films and series with the part in each. Pages stack; from a title's
"Meer zoals dit" or a person's work the next title goes on top, Esc (or ⌘[ and the back
button) walks back, the sidebar always lands on the rows. Left and right on a title
opened from the rows move to the neighbouring card.

In the app:

- Scope: Samen or your own name. "Yes" (`J`) goes to the current scope's list.
- In Samen, "Op jouw lijst, nog niet samen" shows only your own entries.
- Trailers (`TrailerPlayer.swift`) exist only after a click: YouTube through its IFrame
  API in a `WKWebView` whose base URL is the Burrow server (YouTube refuses embeds without
  an origin), direct streams in `AVPlayerView`. The status line says "Speelt af" only on
  the player's own event, else "Speler geladen". Esc, closing and another title tear the
  view down, which stops the sound.
- A series with more than one season gets a season menu (all, the first, or a set)
  next to the list button; the pick goes with the list call and so to Seerr.
- An available title shows a "Kijken" row once Jellyfin has answered (asked after the
  details, so a slow Jellyfin never holds them back): "Op <tv>" or a menu of screens, and
  "Hier", which opens the page in the browser. `K` (⌘K) starts on the only screen, opens
  the page when none is open, and asks when several are; ⇧⌘K is always the page.
- Keys: ⌘1 Ontdekken, ⌘2 Zoeker, ⌘3 Lijst, ⌘4 Films, ⌘5 Series, ⌘F search, ⌘R refresh.
- Live: `lumos.changed` reloads the rows; `settings.changed` re-reads who we are and the
  status, so a setting flipped on another Mac shows at once.
- `burrowctl lumos …`: `state` (with the stack, cast, budget and similar titles),
  `show` (also `explore`), `search`, `open`, `person`, `back`, `trailer`, `stop`,
  `close`, `watch [screen=<name>|here]`. The list buttons are marked
  `lumos.approve.list`, because a list entry requests media.

Run the bundles (`scripts/bundle.sh`), not `.build/debug/<App>`: a bare executable has
activation policy "prohibited", never becomes the active app and gets no key presses.
`LUMOS_SERVER` and `LUMOS_KEY` connect either app without the Keychain.

## Not yet

History import (phase 6), curated snippets and taste ranking (7), waking the TV, asking
more seasons of a title that is already requested, and the "Nieuw digitaal" row: see the
plan and `TODO.md`.
