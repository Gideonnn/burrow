---
id: 2026-11-11-outing-code-leaves-hedwigcore
date: 2026-11-11
kind: decision
area: [hogsmeade, hedwig]
topics: [hogsmeade, outings]
---

# The outing code leaves HedwigCore

Hogsmeade imported HedwigCore only for outings, so every outing change rebuilt the mail
app. The outing types and API calls, `OutingStatus`, `PlaceBook`, the ticket readers and
the picture cache now live in `HogsmeadeCore`, with their tests; Hogsmeade depends on
BurrowKit alone and HedwigCore is no longer a library product. Hedwig lost its outing
state, the `.outings` sidebar case and `MailboxRowSlot`.

Two Hedwig types Hogsmeade still used were not outing code: `Me` (it now reads `/api/me`
as BurrowKit's `Profile`, which has everything but the mailboxes) and `MessageDetail`
for the linked mail sheet (now `LinkedMail`, the four fields it shows). Moving the
place book changed its file to `Application Support/Hogsmeade/places.json`: it is a
cache, so the places are looked up again once.

What only Hedwig's old mail card and Evenementen page used went with them:
`OutingSuggestion`, `CreateOutingRequest` (a new outing is four fields, sent as JSON),
the picture backdrop colours and `openPersonalise`. Their tests went too; the card and
selection tests had no counterpart left.

Left as it is: the sidebar's kind symbols (`Outing.symbol(forKind:)`) and the map pin's
(`kindSymbol`) use different word lists and symbols; merging them would change icons.
`Me` in HedwigCore repeats BurrowKit's `Profile` plus mailboxes; it can shrink once
`Profile` can carry the mailboxes.
