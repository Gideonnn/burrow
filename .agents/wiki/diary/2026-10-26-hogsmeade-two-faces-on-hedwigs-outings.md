---
id: 2026-10-26-hogsmeade-two-faces-on-hedwigs-outings
date: 2026-10-26
kind: decision
area: [hogsmeade, hedwig]
topics: [hogsmeade, outings]
---

# 2026-10-26 Hogsmeade: two faces on Hedwig's outings, built in one evening

The outings app, as two apps from one package so the household can compare: Hogsmeade
(native) and Hogsmeade Feest (playful). Both read and change Hedwig's outings; the
server did not change except for two update clients.

## Decisions

- **`HedwigCore` is now a library product.** The outing types, the status sentence, the
  Dutch dates, the place book, the picture cache and the ticket code readers are the
  same code in Hedwig and Hogsmeade; only `OutingPictureCache` had to become public.
  Rejected: moving Hedwig's outing views into a shared library, since they lean on
  Hedwig's whole `AppModel` (mail, selection, drafts); the faces got their own views on
  a small `OutingsModel` instead, which is also what the comparison asks for.
- **Two bundles from one package.** `bundle.sh` takes the product (also through
  `BUNDLE_PRODUCT`, since the kit's release script calls it without arguments) and sets
  the name, bundle id and icon; each face has its own login, cache and client.
- **The playful face's places are Hedwig's.** `PlaceBook.defaultFile` is Hedwig's
  `places.json`, so a venue found in one app is on the map in the other at once.
- **What the designs draw but the server lacks waits:** wishes without a date and stars
  after the night are in `TODO.md`; the weather chip and "kaartjes naar telefoon" are
  not promised.

## Traps

- **`searchFocused` is macOS 15.** The package targets 14, so the native face has its
  own toolbar text field with `@FocusState`, like Lumos.
- **A hidden title bar still leaves its strip.** The night and the cream showed a dark
  band at the top until the backgrounds and the confetti got `ignoresSafeArea()`.
- **`CGWindowListCopyWindowInfo` names windows by the app's display name**, so the
  playful face's window is "Hogsmeade Feest", not its executable `HogsmeadeFeest`.
- **A `change` helper with a defaulted first parameter and a trailing closure** did not
  compile (`missing argument for parameter #1`); the closure goes first, the label last.
- **`Address` has `email`, not `address`.**

## Validation

Five model tests (sorting and today, filters and search, the one stamp, ticking the
last item celebrates, a new outing opens). Both faces ran against the fixture server
with six invented outings and were driven with `burrowctl hogsmeade …` and `burrowctl
hogsmeade-feest …`: the wall with tonight's banner, the page with the map, the night
itself with the clock and the route card, the wall, the scrapbook, Geweest.
