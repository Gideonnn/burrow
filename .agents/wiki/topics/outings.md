# Outings (Evenementen)

An **outing** is something the household goes to: a concert, play, festival or party,
often bought half a year ahead from a ticket shop. Outings are the household's, not one
person's: everyone sees and changes every outing. Code: `modules/hedwig/src/server/outings/`,
contracts in `packages/contracts/src/outings.ts`, the Mac page and card in
`apps/hedwig-mac/Sources/Hedwig/Outing*.swift`. Designs:
[`docs/design/hedwig-events.html`](../../../docs/design/hedwig-events.html) (the page, v2),
[`docs/design/hedwig-cards.html`](../../../docs/design/hedwig-cards.html) (the card, v1) and
the plan in [`docs/plans/2026-10-22-calendars.md`](../../../docs/plans/2026-10-22-calendars.md).

## From a mail

`GET /api/messages/:id/outing` reads the mail (`detect.ts`): schema.org
`EventReservation`/`Event` JSON-LD first (`confidence: structured`), otherwise a known ticket
shop by sender domain or ticket words with a date or a ticket attachment (`likely`). It
returns title, kind, times, venue, shop, order number, the personalisation deadline
("uiterlijk 14 dagen voor het evenement op naam", "op naam vóór 29 april 2027"), aliases and
the attachments that look like tickets (pdf, `.pkpass`, non-inline images). It asks the
provider for attachments only when the mail looks like an outing, so the Mac asks for every
opened mail. `outingId` says the mail already belongs to one.

**Haiku reads the `likely` mail** (`reader.ts`, Kreacher's `outing-details` skill,
cached in `outing_reads`): whether it is about `tickets`, an `addon` (locker, parking),
an `announcement` (presale, voucher codes) or `other`, and the event's own name, times,
place, shop and order number. Its answer wins over the rules' guess; an announcement or
other gets `confidence: none`, so no card. Sensitive mail (mail facts) and bots without
the skill skip it; the text goes redacted. A failed read is tried again the next time.

A mail becomes an outing by itself when it is stored (`adoptStored`) and its night is
still to come: a `structured` one always, a `likely` one when Haiku reads tickets. A
second mail about the same order or the same night joins the existing one; names match
without year and punctuation ("Welcome To The 90s 2026" and "Welcome To The 90's"). An
addon only joins, it never starts an outing. At start `adoptArchive` runs the same over
mail of the last 400 days with JSON-LD or an order-like subject (at most 300). Otherwise
the Mac card offers **Bewaar**, which posts the suggestion with `messageId` and
`attachmentIds`: the outing, the mail linked, the attachments copied as tickets and,
with a deadline, the item "Kaarten op naam zetten".

**Enriching** (`enrich`): after an outing is made or gets a mail, and for every outing
at start, Hedwig looks in every household mailbox for mail of up to 400 days before the
night that names it (the title's first words, or the order number) and has Haiku read
up to 25. Mail that Haiku reads as `tickets`, `addon` or `info` (times, route, "final
info") for the same event is linked; newsletters and presales are not. The readings fill
only empty fields (venue, place, organiser, kind, order number, website, doors, end) and
give a day without a time its time; what someone typed stays. Then the picture is
picked. Angela's mail joins in once her mailbox is connected.

**Line-up** (`lineup.ts`, Kreacher's `festival-lineup` skill, `outing_lineups`): `POST
/outings/:id/lineup` fetches the outing's website (`url`), its line-up or timetable
pages and its newest news pages on the same site (at most 8, 5,000 characters each)
and has Haiku list the acts of this edition with day, stage, time and headliner. The
outing carries `lineup` with `status` working, ready or failed; `DELETE` removes the
widget. Haiku has no internet on Dobby: the server fetches, through `fetchPublic`.
Social media are not read (they need a login and block scrapers).

## What an outing holds

- **Tickets** on disk under `<data>/files/hedwig/outings/<id>/`, from a mail attachment or
  an upload; per ticket a holder and `personalised`. When every ticket is personalised the
  deadline item closes. Facts-only keys get 403 on ticket files and suggestions; MCP tools
  show only holder and status, never the file.
- **Checklist** (`outing_tasks`): `personalise` (from the mail) and `custom` items with a
  due date and an assignee. Older outings may still hold a `calendar` item; new ones never
  get one, because calendar sync will be automatic, and the Mac hides it.
- **Attendees** (Wie): everyone in the household unless `attendeeIds` says otherwise.
- **Mails** (`outing_messages`): a mail in someone else's mailbox shows only that it exists
  and whose it is (`visible: false`, no subject or sender). Only a key that sees the mail
  can link or unlink it.
- **Search words**: `search_text` holds title, kind, venue, organiser, shop, order number
  and aliases; mail search matches linked mails on it, so "90's party" finds the ticket
  shop's order mail.

**Picture** (`pictures.ts`, `images.ts`): one file `image.<ext>` in the outing's folder,
`image` in the contract. Hedwig picks one by itself when an outing gets a mail or a
website and has none: the largest picture of at least 300 by 150 among the mail's remote
images, its inline image attachments and the website's `og:image`/`twitter:image`.
Logos, icons, pixels and anything social (also YouTube) are skipped; nothing social is
ever shown. Someone can choose an option (`GET /image/options`, previews through the
server), paste or drop one (`PUT /image {uploadId}`) or give a link to a picture or a
page (`{url}`); `DELETE` means none and sets `imageOff`, so Hedwig never picks again.
Only PNG, JPEG, GIF and WebP by their bytes, never SVG; served with `sandbox` CSP.
The server fetches, never the Macs, through `fetchPublic`: http(s) on ports 80 and 443,
public addresses only (checked after every redirect), 8 MB at most. The DNS check is not
pinned to the connection, so a rebinding host could still slip through; acceptable for a
household server, worth pinning if the server ever fetches more.

Every change emits `outing.changed` with the id; both Macs reload. Reading needs `read`,
changing `organize`. MCP: `list_outings` (read) and `add_outing` (organize); no delete.

## On the Mac

The Evenementen page follows design v2 (`docs/design/hedwig-events.html`): dead simple for
the family, everything else folded behind **Details**.

- **Sidebar**: the badge counts upcoming outings that need something now: an open item due
  within 28 days (an item without a date is due on the day itself), or no tickets within
  14 days of the date.
- **List**: one status sentence per outing, in this order: "Vanavond"/"Vandaag" with the
  place on the day, "Nog doen: …" (orange) for the most urgent item due within 28 days or
  missing tickets within 14 days, "Later: …" for a later item, "Kaarten toevoegen", or
  "Alles geregeld". Then Geweest. The logic lives in `HedwigCore/OutingStatus.swift`, so
  it is tested without a window.
- **Waar** (`Sources/Hedwig/OutingMapCard.swift`): under Wie, a still map (`MKMapSnapshotter`, light
  or dark) with a pin holding the picture or the kind's symbol, venue and city on a
  material label, and Route (directions in Apple Maps); clicking the map opens the place.
  `MKLocalSearch` asks "venue, address", then the address alone; `PlaceBook`
  (`HedwigCore/OutingPlaces.swift`) keeps the answers in
  `~/Library/Application Support/Hedwig/places.json` by venue and address, so a page
  opens with its map at once. No answer (offline) is asked again next time; not found is
  remembered for the session and shows the plain line with Route. The travel time ("ca.
  25 min met de auto", `MKDirections` ETA) shows only when this Mac already allows
  location; Hedwig never asks by itself, only from the map's menu "Toon reistijd vanaf
  deze Mac". `CLGeocoder` is deprecated from macOS 26, so it is not used.
- **Detail**, top to bottom: the header, Wanneer/Waar/Wie (click a person to toggle), the
  map, the line-up, the tickets, Nog doen with "Iets toevoegen", Details. Dropping a pdf, `.pkpass` or
  image uploads it (`/api/uploads`, then `POST /api/outings/:id/tickets`). Details: every
  field, tickets per person, linked mails (someone else's shows "Mail van …"), search
  words, history and delete.
- **Line-up** (`Sources/Hedwig/OutingLineupView.swift`, grouping in
  `HedwigCore/OutingLineup.swift`): per day ("Vrijdag 2 juli", then "Nog geen dag"),
  headliners large like on a poster, the rest smaller, stage and time small; the note,
  "Bijgewerkt …" and the source host. Refresh spins while the server reads; X removes it.
  Without a line-up an upcoming festival or concert (or any outing with a website) shows
  "Line-up zoeken", disabled with "Voeg eerst de website toe" when there is no `url`.
- **Tickets** (`Sources/Hedwig/OutingTicketViews.swift`): a row of Wallet-like cards, one
  per code, a notch where the stub tears, the holder (or "Kaartje 2/3") and file name
  below. A `.pkpass` shows its own colours and its code drawn from `pass.json`
  (`TicketPass` and a small zip reader in `HedwigCore/OutingTickets.swift`). A pdf or
  image is searched with Vision (`HedwigCore/TicketCodes.swift`: every pdf page rendered
  at about 2000 px, QR, Aztec, PDF417, Data Matrix and Code 128); a found code is drawn
  again from Vision's barcode descriptor (`CIBarcodeGenerator`, the exact symbol), Code
  128 from its text, and only cut out of the page when neither works. No code: a plain
  file card. Codes are drawn module by module without smoothing, on white. Clicking
  opens the code large to scan at the door; arrows step through the cards. Previews are
  kept in memory per ticket id, never on disk. `ticketLinks` (tickets that came as a link) are
  buttons that open the shop page, one per label; without files the block says "Je
  kaartjes staan bij Weeztix".
- **Mail card**: one line, "Staat in Evenementen · nog doen: …" with Bekijk, or Bewaar
  for a `likely` mail. With a picture it shows its thumbnail.
- **Picture** (design `docs/design/hedwig-event-images.html`, views in
  `Sources/Hedwig/OutingPictureViews.swift`): a 44 pt thumbnail at the end of each list
  row (grey for past outings; a calm tile in the title's colours without a picture).
  The page header keeps to about 200 pt and a third of the window: the picture whole on
  the left (at most 160 pt high and 45 % wide, small ones at their own size, never
  stretched), the date, title and kind beside it, on a gradient of the picture's own
  strong colours (`PictureColours`; light behind black text, deep behind white) that
  fades into the page. Text never sits on the artwork, which usually carries its own; a
  blurred copy as backdrop was tried and smeared dark artwork into grey.
  Without a picture the same places get a gradient in the title's colours
  (`TitleColours`, the design's hash) with the kind's symbol (`Outing.kindSymbol`).
  Details › Afbeelding has
  Andere afbeelding (a sheet with the server's options, previews through the server),
  Geen afbeelding, and a drop zone with Plak. Pasting (⌘V, caught by `PasteCatcher`
  whenever no text field is being edited) or dropping on the hero also sets it, while a
  drop elsewhere on the page stays a ticket. `PastedPicture` decides: a copied file wins
  over the icon Finder adds, then image bytes (TIFF and HEIC become JPEG or PNG, at most
  8 MB), then a web link sent as `{url}`. Pictures are cached per outing and `updatedAt`
  (`OutingPictureCache`) and fetched with `?v=`.

**Reminders until Patronus**: the Mac schedules local notifications (UserNotifications,
`Sources/Hedwig/OutingNotifications.swift`) at 09:00 on the day ("Vanavond: …"; at noon
the day before for a start before 10:00) and 28 and 7 days before an open item's due
date. They are rescheduled whenever the outings change; permission is asked once, and
only when there is something to remind of. Each Mac reminds its own person, only of the
outings they go to (Wie).
`swift run` has no bundle, so it schedules nothing; use `bundle.sh`.

## Not yet

Calendar sync to the shared calendar (every outing goes in, without a button) and tickets
to each person's Telegram on the day (Patronus, which then replaces the Mac reminders);
see `TODO.md`.
