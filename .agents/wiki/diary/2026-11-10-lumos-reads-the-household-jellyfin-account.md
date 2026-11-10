---
id: 2026-11-10-lumos-reads-the-household-jellyfin-account
date: 2026-11-10
kind: decision
area: [lumos, server]
topics: [lumos]
---

# 2026-11-10 Lumos goes native and reads the household's Jellyfin account

The redesign in `docs/design/lumos-redesign.html` was built: eight pages became three
(Ontdekken, the list, the Bibliotheek), Smaak and Overgeslagen moved to the settings
window, and the Mac draws standard SwiftUI on macOS 26 with the Lumos colour only as tint.

**Decisions (the owner's):**

- macOS 26 as the minimum for Lumos only, so `.glass` and `.glassProminent` need no
  fallback. `swift-tools-version` 6.2 is what offers `.macOS(.v26)`; BurrowKit stays at 14.
- One shared Jellyfin account: its "played" is "samen gezien"; per person there is only
  Lumos's "Al gezien". Another person's own "Al gezien" is never shown, since personal
  verdicts are private; the Mac shows "Samen" and "you".
- Ruimte maken: seen together, larger than 25 GB, on nobody's list (shared or anyone's
  own), largest first. The server sends only a flag, so nobody learns whose list.
- Deleting a seen title records the household's "Al gezien"; lists stay.

**Traps:**

- **Most files carry no TMDB id.** A probe on Dobby (statuses and counts only) found 3 of
  15 films with `ProviderIds.Tmdb`. Facts are matched by the Jellyfin id Seerr knows
  first. Series also lack `RecursiveItemCount` there; the episodes found are the count.
- **Plain-letter menu shortcuts.** Measured in a probe app: a focused text field keeps
  its letters and ⌫ (so J in the search field types a J), while a SwiftUI `onKeyPress`
  on a focused view sees the key before the menu. So J, N, T, K, V and ⌫ live only in
  the menus and the views no longer handle them; handling both would act twice.
- **The repository's secrets hook** refuses Bash commands that contain `this.db`, `$0.key`
  or a path ending in `.key`; write patches and scripts to files instead.
- Screenshots while someone uses the Mac: activating the app steals their keystrokes
  (a typed "n" opened Niet nu). Capture the window by its id with
  `screencapture -l` and drive the app through `burrowctl`, never by bringing it forward.

**Rejected:**

- Radarr and Sonarr keys for sizes and the disk: Jellyfin's `MediaSources[].Size` and
  `/System/Info/Storage` give both with the key the server already has.
- One Jellyfin call per title: the whole library is two `/Items` calls and a NextUp,
  cached a minute.
- A batch delete route: the Mac calls the per-title delete in turn and stops at the
  first failure.
- `onDeleteCommand` on the table next to a ⌫ menu item: the menu fires first, so one path.
