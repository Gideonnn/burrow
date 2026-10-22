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

A mail read with certainty (`structured`) becomes an outing by itself when it is stored
(`adoptStored`); a second mail about the same order or the same night joins the existing
one. For a `likely` mail the Mac card offers **Bewaar**, which posts the suggestion with
`messageId` and `attachmentIds`: the outing, the mail linked, the attachments copied as
tickets and, with a deadline, the item "Kaarten op naam zetten".

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
- **Detail**: Wanneer, Waar (Route opens Apple Maps), Wie (click a person to toggle),
  Nog doen with "Iets toevoegen", and the tickets. Dropping a pdf, `.pkpass` or image
  uploads it (`/api/uploads`, then `POST /api/outings/:id/tickets`). Details: every field,
  tickets per person, linked mails (someone else's shows "Mail van …"), search words,
  history and delete.
- **Mail card**: one line, "Staat in Evenementen · nog doen: …" with Bekijk, or Bewaar
  for a `likely` mail.

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
