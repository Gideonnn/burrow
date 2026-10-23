---
id: 2026-10-23-pensieve-window-like-hedwig
date: 2026-10-23
kind: trap
area: [pensieve]
topics: [pensieve]
---

# 2026-10-23 Pensieve's v6 window, native like Hedwig

The v6 design became the app with system controls where the HTML drew its own: the
search is `.searchable(placement: .toolbar)`, the actions are a `ControlGroup`, Stuur is
a `ShareLink`, the player is `AVPlayerView`, settings are grouped `Form`s. The sidebar
pieces (counts, section headers, update banner, server card) moved to BurrowUI and Hedwig
uses them too, so both apps draw them the same.

Two traps:

- **Day sections shrink every row.** A `List` with `Section("Vandaag")` headers in the
  content column gave every row one line's height on macOS 26, clipping the second line
  and the thumbnail. The same rows without sections size themselves. Mail and Hedwig have
  no day sections either, so the list dropped them; the date is in each row.
- **SwiftUI's `VideoPlayer` crashes in a package executable** ("failed to demangle
  superclass of VideoPlayerView from mangled name 'So12AVPlayerViewC'") because the
  SwiftUI overlay of AVKit is not linked. `AVPlayerView` in an `NSViewRepresentable` works
  and is the Mac's own player anyway.

Left out because the engine or server cannot yet: pause, the shelf's progress in a row,
"Nieuw uit iCloud", "Verwijderd" and "Open deellinks", and settings for Dobby's copy and
links; see `TODO.md`. A demo against a fake server now sets `PENSIEVE_FOLDER` so its copy
stays out of iCloud Drive.
