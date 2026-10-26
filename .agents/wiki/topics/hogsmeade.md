# Hogsmeade

Hogsmeade is the household's outings app: the concerts, plays, festivals and parties in
[outings](outings.md), with their tickets, the one thing still to do, and the route on
the night, without opening mail. It changes nothing on the server: the outings are
Hedwig's (`/api/outings`, `outing.changed`), Hogsmeade is a window on them. It comes in
two faces from one package (`apps/hogsmeade-mac`), so the household can run both and
pick the one it likes; plan: `docs/plans/2026-10-26-hogsmeade.md`.

## One model, two faces

- `HogsmeadeCore`: `OutingsModel` is the state machine: the connection, who we are and
  the household, the outings (kept on disk under `Application Support/<App>/Cache`, so
  the window opens full before the server answers), the page (Binnenkort, Geweest), the
  sidebar's filter (a person, a kind), the search, the open outing, and every change:
  tasks, who goes, tickets, pictures, the line-up, delete. `today` is the outing on
  today's date, `next` the first to come, `nights(until:)` counts the nights. `lastChange`
  says what just happened (created, a task done, all done, tickets added) for a face that
  wants to celebrate. Tests drive it with a mock server, without a window.
- `HogsmeadeCore` builds on `HedwigCore`, a library product of `apps/hedwig-mac`: the
  `Outing` types, `OutingStatus` (the one sentence), `OutingFormat` (Dutch dates),
  `PlaceBook` (places found once, kept in Hedwig's `places.json`, so a place known in one
  app is known in the other), the ticket code readers and the picture cache. Nothing
  outing-related is written twice.
- `HogsmeadeUI`: what both faces share on screen. `OutingPictureReader` loads a picture
  once per version through the model's cache; `OutingPoster` shows it or the title's
  colours with the kind's symbol; `MapSnapshot` and `PlaceReader` draw the still map
  with the pin; `TicketEntriesReader` reads the codes out of pdfs, passes and
  screenshots (the same readers as Hedwig) and `TicketViewer` shows one big for the
  door; `ConfettiBurst`; the stickers, stamps and pills of the playful face; the menu
  bar (`⌘1`, `⌘2`, `⌘F`, `⌘N`, `⌘R`) and the `burrowctl` commands.
- `Hogsmeade`, the native face (`docs/design/outings-app-native.html`): a sidebar with
  Binnenkort and Geweest, "Wie gaat" (a person's outings) and "Soort" (a kind), each a
  filter; the wall with tonight's outing as a gradient banner (Kaartjes, Route) and the
  rest as posters with the date, the nights left, one status sentence and who goes; the
  page: the poster as hero with the big date and "Nog 32 nachtjes", Wanneer/Waar/Wie
  with the map, Kaartjes as stubs, Nog doen, the line-up, and Details folded away.
  Burrow's tokens, system controls, light and dark.
- `Hogsmeade Feest`, the playful face (`docs/design/hogsmeade-style.html`): a night with
  blurred lights; "HÉ GIDEON, nog 3 nachtjes tot … samen met Eva" and a chip with what
  is still to do; the posters fanned out like a hand of cards (stripes, a date sticker, a
  stamp: Geregeld!, Nog doen, Kaartjes?), the ride (a line through the months with a dot
  per outing), a floating island to navigate. On the day itself the outing takes the
  screen: confetti, "Vanavond!", the title in poster letters, a clock to the doors, the
  tickets as stubs, the route in a glass card, chips with what is done. An outing is a
  page in a cream scrapbook: the poster with washi tape, the nights as a sticker, the
  date as a tear-off page, facts as pills, the map, Nog doen on a notepad, the ticket as
  a stub, the mails as a clipping, and a party button. Its colours are fixed
  (`Palette`), the window forces dark.

Both faces: dropping a pdf, Wallet pass or screenshot on an outing makes it a ticket; a
ticket's menu sets the holder and "op naam"; the poster's menu pastes a picture or a
link or picks one Hedwig found; Esc goes back; each face has its own login, Keychain
item and update channel (`hogsmeade`, `hogsmeade-feest`, clients of the Hedwig module).

## Not yet

Wishes (an outing without a date) and stars after the night, drawn in the playful
design, need server support: `TODO.md`. Reminders stay Hedwig's. After the household's
choice the other face goes, and Hedwig's Evenementen page can follow.
