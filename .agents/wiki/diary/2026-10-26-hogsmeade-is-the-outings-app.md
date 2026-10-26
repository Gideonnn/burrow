---
id: 2026-10-26-hogsmeade-is-the-outings-app
date: 2026-10-26
kind: decision
area: [lumos, hedwig]
topics: [lumos, outings, naming]
---

# 2026-10-26 Hogsmeade is the outings app; the playful Lumos face is undone

The playful style in `docs/design/hogsmeade-style.html` was read as a second face of
**Lumos**, and `apps/hogsmeade-mac` was built, installed and released as that this
evening. Gideon corrected it the same evening: Hogsmeade is the household's **outings**
app, and the two designs (`outings-app-native.html` and `hogsmeade-style.html`) are its
two faces, native and playful, to compare. Lumos is films and series, with Jellyfin.

## Decisions

- **The playful Lumos face is removed**, not kept under another name: the app folder,
  its scripts, the `hogsmeade` client of the Lumos module, the installed app and its
  release folder on Dobby. Commit `c996206` still has the code for anyone who wants the
  wall, the stickers or the confetti back.
- **What stayed:** `LumosCore` and `LumosUI` as library products, the decoded image
  cache, the disk snapshot of the rows, the season menu and `lastChange`. Lumos got faster
  from them, and a second face or a tool can still build on them.
- **Hogsmeade next:** one codebase on the outings API that Hedwig already has, built as
  two bundles with their own name, bundle id and icon, so both faces run side by side.
  `BurrowColor.hogsmeade` and the `hogsmeade` module name in `BurrowUI` stay for it.

## Trap

- **"De speelse variant daarvan" after a message about Lumos** was read as "of Lumos".
  When a design file is named after an app, the app it belongs to is the one in its
  title, not the one the conversation was about last.
