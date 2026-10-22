# Calendars on Dobby (Weasley Clock, first step)

Plan of 2026-10-22. Decisions agreed with Gideon are marked **(agreed)**. Design:
[`docs/design/weasley-clock.html`](../design/weasley-clock.html); the cards that use it:
[`docs/design/hedwig-cards.html`](../design/hedwig-cards.html).

Burrow syncs the household's calendars to Dobby, from the same accounts that bring the
mail. That gives the Hedwig cards free/busy and RSVP, lets agents read and add events,
and tells each person what the other added to a shared calendar, as iCloud family
calendars did. It is the first step of the Weasley Clock, the household's own calendar;
the store built here becomes its data.

## Decisions

- **Sync on Dobby, not EventKit on the Mac (agreed).** Calendars come in at connect time,
  like Apple's Internet Accounts: one login, with switches for Mail, Agenda and
  Contacten. Notes are never offered.
- **A shared calendar counts once.** The household's shared calendar ("Wij", owned by
  one adult's Google account and shared with the other) is one `calendars` row with both
  people as members, however many logins see it.
- **Agents may add events (agreed in spirit: "ask Dobby or a bot in Telegram").** Rules
  below; inviting guests sends mail, so it always needs the person's click.
- **Change notices (agreed):** "Eva heeft Ouderavond toegevoegd aan Wij", to the other
  members, never about your own change.
- **Answering an invite** happens only on a click in the Hedwig card **(agreed)**; with a
  synced calendar it goes through the provider's own respond call, so your calendar and
  the organiser both update.

## Accounts

One connection per provider account, with the services the person switched on. Existing
mail connections reconnect once to add Agenda and Contacten.

| Provider | Agenda | Contacten | Setup |
|---|---|---|---|
| Google | OAuth scope `calendar` (read and write events) | `contacts.readonly` (People API) | Enable Calendar API and People API in the Cloud project, add the scopes to the consent screen. Still unverified: one warning click. |
| Microsoft | Graph `Calendars.ReadWrite` | `Contacts.Read` | Add the delegated permissions; a work tenant may need its admin. |
| Fastmail | CalDAV with an app password (Fastmail's API tokens list no calendar scope) | JMAP contacts on the API token | A second field when Agenda is on. |
| iCloud | CalDAV with an app-specific password | CardDAV | Not needed now: "Wij" lives in Google. |

## Sync

- Google: `events.list` per calendar with a `syncToken`, polled every minute; push
  channels later (they need a public webhook through the tunnel, past Access).
- Microsoft: `calendarView/delta`. CalDAV: `sync-collection` (RFC 6578), ctag as fallback.
- Recurring events are stored as the series plus exceptions; occurrences are expanded
  for a window (a year back, two years ahead) when asked, not stored.
- Tables: `calendars` (provider id, name, colour, owner, members, access read or write),
  `events` (uid, provider id and etag, times with time zone, all-day, recurrence,
  title, location, notes, meeting URL, creator, organiser, attendees, my answer,
  `updated`), `event_changes` (added, changed, moved, removed; by whom or unknown; via
  which bot; at).
- Invites Hedwig reads from mail link to the event with the same UID.

## Who changed what

- **Added:** the provider names the creator (Google `creator`, Graph `organizer` for
  shared calendars, CalDAV usually nothing). Burrow maps the address to a household
  person.
- **Changed or removed outside Burrow:** Google, Microsoft and CalDAV do not say who did
  it. The notice then has no name: "Etentje bij Sanne is verplaatst naar za 18:30". It
  can reach the person who made the change; to keep that rare, change notices are only
  sent for time, place and cancellation, not for a new note.
- **Through Burrow** (an app, an agent) Burrow knows the person and the bot, so the
  notice says "Gideon (via Kreacher)".
- Once the Weasley Clock serves calendars itself (CalDAV from Dobby to the phones), every
  change passes through Burrow and every notice has a name, as with iCloud.

## Notices

- To every member of a shared calendar except the one who made the change, per calendar
  switchable ("Meldingen voor Wij").
- Changes within two minutes are bundled: "Eva heeft 3 afspraken toegevoegd aan Wij".
- Channels: a macOS notification from the Burrow apps, the Vandaag strip in Hedwig
  ("Nieuw in Wij"), and Telegram once Patronus exists. Quiet hours follow the person's
  settings.
- Changes to events in the past and the initial sync never notify.

## Agents

- MCP and bot tools: `list_events`, `free_busy`, `add_event`, `update_event`,
  `delete_event`, scoped to the calendars the key may see.
- Two new key rights: `calendar` (read) and `calendar-write`. A bot may hold both.
- A bot adds or changes events without asking, but never adds guests (that sends
  invitations by mail) and never deletes an event it did not create; both become a task
  that waits for the person's click.
- Every bot change is logged in `event_changes` with the bot, shows "via Kreacher" in the
  notice and can be undone from the notice or the chat for a day.
- Telegram: "Zet zaterdag om zes etentje bij Sanne in Wij" becomes `add_event` by
  Kreacher; Patronus answers with the event and Ongedaan maken.

## Events and tickets

Concerts, theatre, festivals and parties are often booked half a year ahead through a
ticket shop (Weeztix, Ticketmaster, Eventbrite) whose mail never names the event the way
you search for it, and some need the tickets in your name before a deadline.

- **Hedwig card Evenement** for an order mail: date, venue, a checklist and the tickets.
  Recognised from schema.org `EventReservation`, ticket shop templates, or Winky.
- **In agenda, one click (agreed):** creates the event in the shared calendar with the
  tickets and the mail attached; the other member gets the usual notice.
- **Tickets on the event**, automatically from the mail (pdf, Wallet pass `.pkpass`) or by
  hand (a pdf, a screenshot, another mail). Hedwig does not download attachments yet
  (it points to the webmail), so storing them is a prerequisite; the platform's uploads
  hold them.
- **Checklist:** in agenda, tickets stored, and deadlines read from the mail ("uiterlijk
  14 dagen voor het evenement op naam") with reminders four weeks and one week before,
  in Vandaag and as a notice. Personal items can be added by hand.
- **Found by every name:** the event's title, kind ("90's party"), artist, venue,
  organiser, shop and order number become search words of the event and of every mail
  linked to it; extra aliases can be added. Later mails join by order number, or by
  event name and date.
- **On the day:** Vandaag and the card show doors and start, Kaarten tonen (QR at full
  brightness) and the route.
- **Later, a page Uitjes:** upcoming events with their ticket status, past ones below.
- Tickets are sensitive (a QR code is money): they never go to a cloud AI, and Telegram
  gets only a pointer to the app.

## Phases

1. **Accounts with services.** The switches at connect time, the new scopes and the
   reconnect flow; contacts stored but unused for now. Half a day to a day.
2. **Calendar sync and store** for Google first ("Wij"), then Microsoft and CalDAV. Two
   days.
3. **Change notices** with bundling, to the Mac apps and the Vandaag strip. A day.
4. **Agent tools and rights**, Telegram once Patronus exists. A day.
5. **Hedwig cards** use it: free/busy, RSVP via the provider, In agenda (the cards plan
   in `TODO.md`).
6. **Events and tickets:** attachment storage, the Evenement card, tickets and checklist
   on events, aliases in search, the Uitjes page. About three days.

## Open

- The module: `modules/weasley-clock` (package `@burrow/weasley-clock`), with Hedwig
  depending on it for the cards. Contacts may later move to their own module.
- Whether the other adult connects her own Google account too. Not needed to see "Wij",
  but needed for her own calendars, and her notices need her to be a Burrow person with a
  channel (her Mac or Telegram).
