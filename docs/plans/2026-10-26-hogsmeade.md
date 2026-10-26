# Hogsmeade: the household's outings, in two faces

Plan of 26 October 2026. Hogsmeade is the outings (Evenementen) app: concerts, plays,
festivals and parties the household goes to, with their tickets, the one thing still to
do, and the route on the night. The outings themselves already exist: Hedwig reads them
from ticket mails and keeps them on the server (`modules/hedwig/src/server/outings/`,
`packages/contracts/src/outings.ts`, the wiki topic `outings.md`). Hogsmeade is a window
on exactly that data, so the household can see outings without opening mail.

Two faces, so Gideon and his partner can pick the one they like:

- **Hogsmeade** (native): `docs/design/outings-app-native.html`. A Mac window with a
  sidebar (Binnenkort, Geweest, who goes, kinds), a poster wall with tonight on top, and
  a page per outing: hero, Wanneer/Waar/Wie with the map, the tickets, Nog doen, Details.
- **Hogsmeade Feest** (playful): `docs/design/hogsmeade-style.html` and the clickable
  `hogsmeade-style-proto.html`. A night with the posters fanned out like a hand of cards,
  a greeting that counts the nights, the day itself as a party with confetti and a clock,
  and every outing as a page in a scrapbook.

## Decisions

- **One model, two faces, both on Hedwig's outings.** `apps/hogsmeade-mac` is one Swift
  package: `HogsmeadeCore` (the outings model, tested without a window), `HogsmeadeUI`
  (what both faces share on screen: pictures, the map, ticket codes, confetti) and two
  executables. `HedwigCore` becomes a library product of `apps/hedwig-mac`, so the
  outing types, the status sentence, the Dutch dates, the place book and the ticket code
  readers are the same code in Hedwig and Hogsmeade. Rejected: copying them, which made
  Lumos's second face a day's work to keep equal.
- **Two bundles, not a switch.** Each face is its own app with its own name, bundle id,
  icon, login and update channel (`hogsmeade`, `hogsmeade-feest` as clients of the
  Hedwig module), so both run side by side on one Mac for the comparison.
- **The server does not change.** Hogsmeade uses `/api/outings` and `outing.changed` as
  Hedwig does. Wishes (outings without a date) and stars after the night, drawn in the
  playful design, need server support and wait in `TODO.md`.
- **Hedwig keeps its Evenementen page** until the household has chosen; then the losing
  face goes and Hedwig's page can follow.

## Phases

1. **Core and the native face** (26 October): the package, the model with tests, the
   shared views, Hogsmeade with the wall and the page, scripts, icons, docs.
2. **The playful face** (26 October): Hogsmeade Feest with the wall, the night itself and
   the scrapbook.
3. **After the choice**: remove the other face, move the Evenementen page out of Hedwig
   or keep it as a card on a mail only, wishes and stars if wanted.
