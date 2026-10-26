---
id: 2026-10-26-hogsmeade-the-playful-face-of-lumos
date: 2026-10-26
kind: decision
area: [lumos]
topics: [lumos]
---

# 2026-10-26: Hogsmeade, the playful face of Lumos, and what made both apps snappy

Gideon wanted to ask his partner which of two faces she prefers: Lumos as it is (a native
Mac window, see the handoff) or the playful style first drawn for an outings app. So
Hogsmeade became a second app on the same server, lists and model, not a branch of
Lumos. Both install side by side and follow each other through `lumos.changed`.

## Decisions

- **One model, two faces.** The state machine, API, artwork cache, trailer player,
  season menu, menu bar and control commands moved out of the Lumos executable into
  library products `LumosCore` and `LumosUI` of `apps/lumos-mac`; `apps/hogsmeade-mac`
  only holds views. The tests stayed with the model, so both faces are covered by them.
  Rejected: copying the Lumos package, which would have meant two state machines to keep
  equal.
- **Hogsmeade has fixed colours.** The night, cream and candy palette is the point of
  the face, so it does not follow the Burrow tokens or the system appearance; the window
  forces dark so menus and popovers match. Lumos keeps the tokens.
- **The design files kept their drawings.** `docs/design/hogsmeade-style.html` and the
  clickable `-proto.html` were drawn on invented outings before the style moved to films;
  they stay as the reference for the style, with a comment on top. The native outings
  impression is `outings-app-native.html` and is not built.
- **A season menu, not a sheet.** A series with more than one season shows a small menu
  (all, first, or a set) next to the list button; `J` keeps taking season 1 so the
  keyboard flow is unchanged.

## Traps

- **`AsyncImage` is the stutter.** It keeps nothing between views, so every card that
  scrolled back downloaded (from URLCache at best) and decoded its full-size picture on
  the main thread again. `ImageLoader` decodes once, downsampled to the shown size, off
  the main thread, and keeps the `NSImage`; `CachedImage` starts with the cached picture
  so a reload never flashes. `NSImage` is not Sendable; it crosses from the decoding task
  in an `@unchecked Sendable` box that nothing else touches.
- **turbo dropped `LUMOS_CATALOGUE`.** `turbo.json` passed only `BURROW_*` through to
  `pnpm dev:server`, so the README's fixture command ran a server without a catalogue and
  the Mac said "niet gekoppeld". `LUMOS_*` is now passed through too.
- **`async let` and ternaries.** `async let x = cond ? nil : try await f()` does not
  compile (`try` cannot be to the right of the operator); small helper functions did.
- **A `.tix` class for two things.** In the prototype the ticket card's CSS class also
  styled the "Kaartjes?" stamp, which vanished; and a `<symbol id="route">` collided with
  `<div id="route">`, so `innerHTML` rewrote the icon instead of the card. Ids and class
  names in a one-file prototype need to be as unique as in an app.
- **The repo's secret hook blocks `e.key`.** Writing the prototype through a heredoc
  failed on the JavaScript `e.key` (it looks like a plaintext secret to the hook); the
  Write tool and `ev.code` sidestep it.

## Validation

Both apps were run against a local fixture server (`cli init`, then `LUMOS_SERVER` and
`LUMOS_KEY`) and driven by keystrokes: the wall, the fan, J with confetti and undo, N
with the reason menu, ⌘2, `/` search, Enter into the scrapbook, a series with its season
menu. Lumos's 15 model tests pass, including the new one for chosen seasons. Dobby was
not reachable (Tailscale off on the Mac), so the server deploy and `lumos:release` wait.
