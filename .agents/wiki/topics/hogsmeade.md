# Hogsmeade

Hogsmeade is the household's outings app and the only Mac app for them: the concerts,
plays, festivals and parties in [outings](outings.md), with their tickets, the one thing
still to do, the linked mails and the route on the night. The outings are Hedwig's
module on the server (`/api/outings`, `outing.changed`); the server finds them in mail
by itself, Hogsmeade shows and edits them. One native face (`apps/hogsmeade-mac`,
`docs/design/outings-app-native.html`) that follows the macOS HIG; the playful face that
was built to compare with it was dropped. Plan: `docs/plans/2026-10-26-hogsmeade.md`.

## The package

- `HogsmeadeCore`: `OutingsModel` is the state machine: the connection, who we are and
  the household, the outings (kept on disk under `Application Support/Hogsmeade/Cache`,
  so the window opens full before the server answers), the sidebar's `Place` (Binnenkort,
  Geweest, a person, a kind; its raw value is what a window remembers), the search, the
  open outing, the edit sheet and picture picker in use, and every change: tasks, who
  goes, tickets, pictures, the line-up, search words, moving or letting go of a mail,
  delete. `OutingDraft` turns the edit sheet into a patch of only what changed;
  `reminders()` lists the Mac's notifications for the outings its person goes to. Tests
  drive it with a mock server, without a window.
- `HogsmeadeCore` builds on `HedwigCore`, a library product of `apps/hedwig-mac`: the
  `Outing` types and API calls, `OutingStatus` (the one sentence), `OutingFormat` (Dutch
  dates), `PlaceBook` (places found once, kept in Hedwig's `places.json`), the ticket code
  readers, the picture cache and `Outing.reminders`. Nothing outing-related is written
  twice; only the mail link and unlink calls live in `OutingDraft.swift`.
- `HogsmeadeUI`: the views that are not one screen: `OutingPoster`, `DateTile`,
  `MapSnapshot` (a button that opens Maps), `TicketEntriesReader`, `TicketViewer`,
  `NewOutingSheet`, `Avatar`, the menu bar and the `burrowctl` commands.
- `Hogsmeade`: the window. A sidebar `List(selection:)` with Binnenkort and Geweest, "Wie
  gaat" and "Soort", remembered per window; search in the toolbar; the wall with
  tonight's outing as a gradient banner (Kaartjes, Route) and the rest as posters; an
  outing opens in a `NavigationStack`, so back, forward, ⌘[ and swipe are the system's.
  The page: the poster as hero with the date and "Nog 32 nachtjes", Wanneer/Waar/Wie/
  Notities with the map, Kaartjes as stubs, Nog doen as checkboxes, the line-up, and
  Details (mails, search words, history, Wijzig, delete). `EditOutingSheet` (⌘E),
  `PicturePickerSheet` and `MailSheet` (a linked mail as text) are sheets. `Reminders`
  schedules the local notifications. System backgrounds and text styles; the app colour
  is only the tint; the posters, the banner and the ticket stubs keep their colours.

Dropping a pdf, Wallet pass or screenshot on an outing makes it a ticket; a ticket's menu
sets the holder (a person, someone else, nobody) and "op naam" and offers Quick Look;
⌘V on a page or the poster's menu sets the picture; Esc goes back. The update channel
and Keychain item are `hogsmeade`.

## Not yet

Wishes (an outing without a date), stars after the night and merging two outings need
server support: `TODO.md`. A linked mail shows as plain text; opening it in Hedwig needs
a way for one app to open a mail in the other.
