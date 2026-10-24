---
id: 2026-10-25-lumos-trailers-and-keys-on-the-mac
date: 2026-10-25
kind: trap
area: [lumos]
topics: [lumos, agent-control]
---

# 2026-10-25 Lumos's trailers play inline; four traps with keys and focus

**Trailer spike, measured in the app against the fixture server:**

- Palm Springs (`pI5w1I6IX40`) and The Holdovers (`xp-AvgbyXRU`) play in a `WKWebView`
  in the inspector through the YouTube IFrame API on youtube-nocookie.com, with the page
  loaded by `loadHTMLString` and the Burrow server (here `http://127.0.0.1`) as base URL
  and `origin`. The player reported state 1 (playing) within two seconds, with picture,
  and autoplay with sound after the click worked with
  `mediaTypesRequiringUserActionForPlayback = []`.
- Sintel's MP4 plays in `AVPlayerView`; `timeControlStatus` reported playing.
- Stopping: tearing the view down on Esc, close and another title removed WebKit's
  "HTMLMediaElement playback" power assertion at once; coreaudiod's speaker assertion
  fell away within seconds, so no sound keeps playing. Checked with `pmset -g assertions`.
- A loaded page proves nothing: the status line says "Speelt af" only on the player's
  own event. Quality is YouTube's choice in a small frame; "Groot beeld bij bron" opens
  the source.

**Traps:**

- `.build/debug/Lumos` runs with activation policy "prohibited": it shows a window but
  never becomes the active app, so it gets no key presses at all. Run the bundle.
- A popover never received key presses, so the "Niet nu" menu's choice moved into the
  model and the rows or the inspector drive it with arrows, Enter and Esc.
- `.focusable()` on a `Group` lands on its children; when the inspector switched from
  its spinner to the details, focus vanished and J, N, T and Esc did nothing. One
  stable `ZStack` holds focus now.
- Esc arrives as the cancel command: `.onExitCommand` catches it where `onKeyPress` did
  not.

`osascript` key codes after `NSRunningApplication.activate` drove the keyboard tests in
the real app; `burrowctl lumos` drove trailers and state.
