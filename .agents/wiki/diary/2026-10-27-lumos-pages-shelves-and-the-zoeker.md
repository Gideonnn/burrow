---
id: 2026-10-27-lumos-pages-shelves-and-the-zoeker
date: 2026-10-27
kind: decision
area: [lumos, server, platform]
topics: [lumos, testing]
---

# 2026-10-27 Lumos grows up: pages over the rows, the shop's shelves, the Zoeker, live settings

An overnight pass on Lumos and the platform before the second Mac joins: the drawer
became a page, the catalogue became browsable, people got pages, and settings became
live everywhere.

## Decisions

- **A page over the rows, not a drawer.** The inspector could not hold cast, money,
  seasons and more like it, and it moved the rows. The page replaces the rows in the
  same column with a 120 ms fade; the rows stay exactly as left underneath, so Esc is
  instant. Pages stack (title, person, title…) so Esc walks back; the sidebar always
  lands on the rows.
- **Fast by cache and prefetch, not by a thinner page.** Details stay in memory (80
  titles, five minutes) and the cursor and the mouse fill the cache 150 ms after they
  settle, with the artwork warmed; a second open makes no request (tested). Any list or
  verdict change clears the cache, because it changes what every detail says; that costs
  one request for the open title and nothing else.
- **Seerr's discover is enough for "all films and series".** Popular, new, upcoming,
  top, trending and hidden gems are TMDB sorts and vote floors; genre, decade and the
  original language are its filters. No TMDB key, no new source. Rejected: a crawl into
  Burrow's own database, which would only lag TMDB.
- **TMDB's recommendations replace the overlap rows.** "Meer zoals dit" was the pool's
  shared genres and traits, which only knew what was trending; TMDB knows every title.
  The pool's overlap stays for the fixtures.
- **Genres in Dutch, language as a word.** The mood chips compared Dutch names with
  English genres and never matched; `/genres` is now asked in Dutch and the original
  language goes through `Intl.DisplayNames`. Synopses stay English by decision.
- **Settings and the household are live.** `settings.changed` (to the person) and
  `household.changed` (to everyone) go on the event stream; the shared settings model
  follows them itself, so a setting flipped on one Mac shows on the other at once.
- **Latency has a ceiling in the tests.** `apps/server/src/perf.test.ts` measures the
  routes the Macs lean on against the fixtures and fails above a per-route p95; the
  numbers print in the test log. `infra/scripts/latency.sh` does the same against the
  live server with a key from the environment.

## Traps

- **The `change` helper's order.** A defaulted first parameter before a trailing closure
  does not compile; the closure goes first.
- **`$0` through perl.** A perl substitution turned `$0` into `-e` in Swift strings; use
  `sed` with a literal, or the Write tool.
- **`.searchFocused` is macOS 15**, kept behind `#available` in Lumos.
- **The sidebar and the stack.** `show(page)` must close the pages over the rows, or
  the sidebar highlights a page the person cannot see.
- **A hook that blocks `r.key`.** The repository's secret hook refuses a heredoc with
  `r.key` in it; tests with that pattern are written through the Write tool.

## Validation

Lumos: 21 model tests (the page cache and prefetch, the person stack, the shelf's pages
and filters). Server: 41 Lumos tests (browse with Seerr's parameters, details with
money, cast and seasons, related titles, people, the Zoeker with its seed), the live
settings tests and the latency ceilings. Both faces of the catalogue were driven with
`burrowctl lumos …` against the fixture server and against Dobby's real catalogue.
