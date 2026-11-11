# Lumos

Lumos helps the household choose films and series to watch together: a native Mac app
with three pages (Ontdekken, the list, the Bibliotheek), and a module on the server with a catalogue provider,
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
- every answer is mapped field by field (`seerr-map.ts`); a test feeds the key and user records through
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
  The writes and the undo live in `changes.ts`; `lumos.ts` only orchestrates.
- The proposals' weighing (`rank`, "Lijkt op", the seed of "Meer zoals") is in
  `ranking.ts`, pure functions over one request's lists and verdicts.
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
sent request is never cancelled; removing a title from a list leaves Seerr alone. Series ask the
seasons chosen in the season menu, season 1 when none was chosen (and always with `J`).
The fixtures never request.

## The Bibliotheek

`GET manage` reads Seerr's `/media` fresh (pending, processing, and `allavailable` by
`mediaAdded`): `busy` with the live download progress and the bytes still to come,
`library` with what the media server holds. Each item also carries what Jellyfin knows
(`server`: size, media facts, `watched`), Lumos's own "Al gezien" (`seen`: the
household's and the asking person's) and `spaceCandidate`; the answer carries the `disk`.

- **Ruimte maken** proposes what was seen together (Jellyfin played), is larger than
  25 GB, Radarr or Sonarr manages, and is on nobody's list, the shared one or anyone's
  own. Only the flag leaves the server, never whose list.
- `DELETE library/:mediaType/:tmdbId` needs `admin` (no bot can hold it) and asks Seerr's
  `DELETE /media/{id}/file`, which has Radarr or Sonarr delete the title with its files,
  then `DELETE /media/{id}`, so Seerr forgets it and its requests. The outbox row turns
  `dropped`, so a new "Ja" asks again; lists stay. A title that was seen (Jellyfin played,
  or anyone's "Al gezien") gets the household's "Al gezien", so it is not proposed again.
  The Mac deletes several titles one call at a time.
- Only a title with Seerr's `externalServiceId` is `removable`: for a file copied in by
  hand Seerr would only mark it deleted and leave the file, so Lumos refuses with 409.
- The title detail carries the same as `library` (null without Seerr, so the fixtures
  claim nothing about files) and `seen`.

## Watching

`JellyfinPlayer` (`jellyfin.ts`) is on when `LUMOS_JELLYFIN_URL` and
`LUMOS_JELLYFIN_API_KEY` are set (`LUMOS_JELLYFIN_WEB_URL` when browsers in the house
reach Jellyfin at another address). `status.watch` tells the Macs. The key is Jellyfin's
service key from the media stack's root-only secrets; the operator's `tv` repository
has `media/host/connect-lumos-jellyfin.sh`, run through `root-run.sh`, which copies it
into the server settings without showing it, like the Seerr one. Nothing in Jellyfin is
ever deleted or marked; the only write is telling a screen to play.

**The household's account.** The household watches on one Jellyfin account, so its
"played" means seen together; per person "seen" comes only from Lumos's verdicts.
`LUMOS_JELLYFIN_USER` (a name or an id, set by the operator in the server settings)
names it; `/Users` resolves it exactly, and without it, or when nothing matches, no user
data is read and no account is guessed. Read for that account, never written:

- the library in two `/Items` calls (`recursive`, `includeItemTypes=Movie,Series` with
  `ProviderIds,MediaSources,RecursiveItemCount`, and `Episode` with `MediaSources`) plus
  one `/Shows/NextUp`, cached a minute: played, play count, last played, the position,
  played episodes of the episodes on disk, the size (sum of `MediaSources[].Size`) and
  the facts of the first file (resolution from the video's width, HDR from
  `VideoRangeType`, audio and subtitle languages in Dutch). Without the account the size
  and facts still come; only `watched` is null.
- a title is matched by the Jellyfin id Seerr knows (`mediaServerId`), else by
  `ProviderIds.Tmdb`: on Dobby only 3 of 15 films carry a TMDB id. Series lack
  `RecursiveItemCount` there, so the episode count is the episodes found.
- `/UserItems/Resume` plus NextUp make the **Verder kijken** row, first on Ontdekken;
  `watch` answers `resume`, and starting on a screen passes `startPositionTicks` (from
  the screen's own user, else the household's), so K picks up where the household
  stopped. A title played to the end starts from the beginning.
- played titles leave the proposal rows (rows and the Zoeker) like "Al gezien" and weigh
  similar titles lightly up; search, the grid and the lists still show them.
- the disk from `/System/Info/Storage` (admin key): every library folder's device once,
  free plus used is the total. No Radarr or Sonarr key was needed.

All of this was checked against Jellyfin 12.3.0 on Dobby with the probe recipe in the
Jellyfin 12 diary entry, and against the 12.4 OpenAPI document.

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

The Mac is drawn as macOS 26 draws standard SwiftUI (`docs/design/lumos-redesign.html`),
with the Lumos colour only as `.tint`; it needs macOS 26 (glass buttons on the artwork).
The pages, in the sidebar's order, with the disk meter under them (orange under 15 %
free):

- **Ontdekken**: one row of filters: Alles, Films, Series (segmented), Sorteer (Voor
  jullie or jou, Populair, Nieuw, Binnenkort, Best beoordeeld, Verborgen parels), Genre
  with the moods Luchtig, Spannend and Rustig first, Decennium, Nederlands and Verras me.
  Without a filter it is rows: Verder kijken, Voor jullie samen, Op jouw lijst nog niet
  samen and Meer zoals from `/rows`, then the Zoeker's rows from `/explore`, both with
  the kind as `type`. A mood makes a grid of those rows' titles; every other filter is a
  grid from `/browse`, films and series taking turns when the kind is Alles (a genre is
  matched by name per kind). The search field searches the catalogue here: the server
  reads three pages of Seerr's `/search` (TMDB matches whole words and puts obscure exact
  matches, series and people first), adds the trending, held and listed titles whose name
  has a word starting with the query ('dead' finds Deadpool), ranks by how well the name
  fits plus log vote count and popularity (a held title a little higher; a matching
  person's work just below a matching name), and filters by the kind (`type`).
- **Onze lijst** / **Jouw lijst**: a grid; the search filters it on the Mac, every typed
  word in any order, ignoring case and accents (the Bibliotheek too).
- **Bibliotheek**: the disk as a stacked bar (films, series, other, what downloads still
  need, free), Ruimte maken for an admin, segments Alles, Films, Series and Bezig, a
  watched filter, and a `Table` (Titel, Gekeken, Toegevoegd, Grootte) with Finder-style
  selection, sorting and column widths kept per window, a context menu, rows to drag onto
  the list, and an inspector (⌥⌘I). ⌫ asks before deleting (Annuleer is the default);
  a hand-copied title shows a lock and why. Z says a delete cannot be undone.
- **Settings** (⌘,): Algemeen, Smaak and Overgeslagen for both scopes, Huishouden.

A title opens on a `NavigationStack` over the page (`TitlePage.swift`), with the system's
back button: the artwork large across the top with the title and glass buttons (Kijken
or Kijk S1E4, the list, Niet nu, Trailer), the story beside **Op Dobby** (size, added,
seen together and by you, picture, audio, subtitles, who manages it, Verwijderen), the
trailer under the artwork while it plays, then scores per source, Productie (budget and revenue with the ratio, studio, collection, dates),
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
- A title on Dobby shows where it plays once Jellyfin has answered (asked after the
  details, so a slow Jellyfin never holds them back): "Op <tv>" or a menu of screens, and
  "Hier", which opens the page in the browser. `K` starts on the only screen where the
  household stopped, opens the page when none is open, and asks when several are; ⇧⌘K
  is always the page.
- Keys: J, N, T, K, V and ⌫ are menu key equivalents (menus Titel and Weergave); a text
  field keeps its own letters, so typing in the search field never triggers them, and a
  view's `onKeyPress` that handled them would fire before the menu, so the views only
  move, open and close. ⌘1 Ontdekken, ⌘2 the list, ⌘3 Bibliotheek, ⌘4 and ⌘5 Ontdekken
  with only films or series, ⌘F or `/` search, ⌘R refresh, ⌘[ back.
- What happened goes to a status bar under the page with Herstel, not a toast.
- Live: `lumos.changed` reloads the rows; `settings.changed` re-reads who we are and the
  status, so a setting flipped on another Mac shows at once.
- `burrowctl lumos …`: `state` (with the filters, the Bibliotheek's rows, disk and
  selection, the stack, cast, budget and similar titles), `show page=discover|list|library`,
  `filter kind=… sort=…`, `search`, `open`, `person`, `back`, `trailer`, `stop`,
  `close`, `watch [screen=<name>|here]`. The list buttons are marked
  `lumos.approve.list`, because a list entry requests media.

Run the bundles (`scripts/bundle.sh`), not `.build/debug/<App>`: a bare executable has
activation policy "prohibited", never becomes the active app and gets no key presses.
`LUMOS_SERVER` and `LUMOS_KEY` connect either app without the Keychain.

## Not yet

History import (phase 6), curated snippets and taste ranking (7), waking the TV, asking
more seasons of a title that is already requested, and the "Nieuw digitaal" row: see the
plan and `TODO.md`.
