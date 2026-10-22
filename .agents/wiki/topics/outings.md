# Outings (Evenementen)

An **outing** is something the household goes to: a concert, play, festival or party,
often bought half a year ahead from a ticket shop. Outings are the household's, not one
person's: everyone sees and changes every outing. Code: `modules/hedwig/src/server/outings/`,
contracts in `packages/contracts/src/outings.ts`, the Mac card in
`apps/hedwig-mac/Sources/Hedwig/OutingCard.swift`. Designs:
[`docs/design/hedwig-cards.html`](../../../docs/design/hedwig-cards.html) (the card) and
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

The Mac shows the card above such a mail; **Bewaar als evenement** posts the suggestion
with `messageId` and `attachmentIds`: the outing, the mail linked, the attachments copied
as tickets, and the checklist items "In de agenda zetten" and, with a deadline, "Kaarten
op naam zetten".

## What an outing holds

- **Tickets** on disk under `<data>/files/hedwig/outings/<id>/`, from a mail attachment or
  an upload; per ticket a holder and `personalised`. When every ticket is personalised the
  deadline item closes. Facts-only keys get 403 on ticket files and suggestions; MCP tools
  show only holder and status, never the file.
- **Checklist** (`outing_tasks`): `calendar` (closes with `inCalendar`; ticked by hand
  until calendar sync exists), `personalise` (from the mail) and `custom` items with a due
  date and an assignee.
- **Mails** (`outing_messages`): a mail in someone else's mailbox shows only that it exists
  and whose it is (`visible: false`, no subject or sender). Only a key that sees the mail
  can link or unlink it.
- **Search words**: `search_text` holds title, kind, venue, organiser, shop, order number
  and aliases; mail search matches linked mails on it, so "90's party" finds the ticket
  shop's order mail.

Every change emits `outing.changed` with the id; both Macs reload. Reading needs `read`,
changing `organize`. MCP: `list_outings` (read) and `add_outing` (organize); no delete.

## Not yet

Calendar sync to the shared calendar (every outing goes in, without a button), tickets
to each person's Telegram on the day, reminders before a deadline, and the Evenementen
page in Hedwig (design v2 in `docs/design/hedwig-events.html`) follow; see `TODO.md`.
