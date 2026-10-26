---
id: 2026-10-26-lumos-watches-through-jellyfin
date: 2026-10-26
kind: decision
area: [lumos, server]
topics: [lumos, secrets]
---

# 2026-10-26 Lumos watches through Jellyfin: a page here, a start on the TV

Phase 5 of the Lumos plan: an available title gets "Hier" (its page in Jellyfin's web
app) and "Op de tv" (a `PlayNow` on the session where the Jellyfin app is open), in both
faces, with `K` for the keyboard.

## Decisions

- **The screen's word, not the command's.** After `PlayNow` the server asks the sessions
  up to six times whether `NowPlayingItem` is the title; only then does the Mac say
  "speelt op LG TV", else "gestart; de tv meldt nog niets". The research of 24 October
  showed a successful API call proves nothing about the picture.
- **By device id, never the first session.** The Mac shows the screens Jellyfin reports
  and plays on the one the person picked; with exactly one screen `K` takes it, with
  several it asks. Rejected: a configured TV device id, which breaks the day the app is
  reinstalled or a second screen appears.
- **The library is asked, "available" is not trusted.** The item comes from Seerr's
  `jellyfinMediaId` when it has one, else from a name search with a matching
  `ProviderIds.Tmdb`. Without an item the page is null and the start answers 400.
- **One service key, through the tv repository.** Like Seerr's: `connect-lumos-jellyfin.sh`
  next to `connect-lumos-seerr.sh`, run by Gideon through `root-run.sh` (the `mediaadmin`
  route was withdrawn on 25 October). The server reads the library only.
- **Waking the TV stays out.** Without a session the button is disabled and says to open
  Jellyfin on the TV; the plan's "not verified" chain is not promised.

## Traps

- **A `Record<string, string>` and a ternary.** `userId ? { userId } : {}` infers an
  optional property, which does not fit the query type; annotate the local.
- **Keystrokes go to the front window.** Driving the app with `osascript keystroke` while
  another window was in front typed into that window. `burrowctl <app> open|watch` and
  `screencapture -l <window id>` drive and capture an app that is not in front.
- **`~/.local/bin/burrowctl` is stale.** It prints nothing; the kit's
  `.build/debug/burrowctl` works. Not fixed here.

## Validation

Seven server tests against a fake Jellyfin 12 (item by id and by name, the episode to
start, confirmed and unconfirmed starts, 409/403/400/404, no key or user data in any
answer, 503 while down or without Jellyfin) and three model tests (`K` on one screen,
none, several; without Jellyfin). Both apps were driven through `burrowctl` against the
fixture server and a fake Jellyfin on `127.0.0.1:18096`. The real TV test waits for the
key on Dobby.
