# TODO

Issue-ready entries, roughly in build order. Delete an entry in the commit that finishes it.

## Finish Dobby (operator)

**What:** connect the real mailboxes (Fastmail with an API token; Gmail and Microsoft
after their client ids are in the settings on Dobby, redirect URI
`<BURROW_PUBLIC_URL>/oauth/callback`); put `OPENAI_API_KEY` and
`BURROW_CONTACT_EMAIL` in the settings and restart; add age recipients for backups.
The Google OAuth app is in production but unverified: people see Google's "unverified
app" warning and continue through Advanced; a Workspace account may also need the client
marked trusted in its admin console.
**Why:** no real mailbox is connected yet, Pensieve stops at transcription without the
key, and backups are unencrypted copies on Dobby itself.
**Scope:** under an hour; see the providers and deploy topics.

## Mail facts: the rest of the plan

**What:** (1) agent work about a sensitive message (summary, reply suggestions) on the
local queue when the owner's Mac has a runner, instead of the redacted body in the cloud;
this needs local bots with those skills. (2) Category and priority per automated sender,
for newsletters whose subject changes every time. (3) Hide Pensieve transcripts from
facts-only keys. (4) Let a runner with a local model take a cloud task that waited ten
minutes, for kinds where a small model is good enough (agreed, not built).
**Why:** left out of the first build of the runners-and-mail-facts plan; see its "What
was built" section.
**Scope:** a day each for (1) and (2), an hour for (3).

## Hedwig cards

**What:** build the cards from `docs/design/hedwig-cards.html` in its four steps: the
`messageCard` contract and a `message_cards` row; the meeting and code cards with the
Vandaag strip and EventKit free/busy on the Mac; parcel, invoice and trip from schema.org;
templates, Winky's optional card and the newsletter card.
**Why:** a meeting, code or parcel mail is read for one fact and one action. Agreed
(22 Oct 2026): an invite is answered only by a click in the card, an invite with a short
organiser note may replace the mail, the strip is called Vandaag. Free/busy and RSVP use
the calendars synced to Dobby (next entry), not EventKit.
**Scope:** step 2 is about two days, the others a day each.

## Calendars on Dobby (Weasley Clock, first step)

**What:** the plan in `docs/plans/2026-10-22-calendars.md` and the design in
`docs/design/weasley-clock.html`: Mail, Agenda and Contacten switches when connecting an
account (never notes), calendar sync for Google, Microsoft and CalDAV with shared
calendars stored once, notices to the other members when someone adds or moves an event
in a shared calendar, and calendar tools and rights for bots.
**Why:** Gideon wants the shared household calendar to tell him what the other added, as
iCloud family calendars did, and to add events by asking a bot; the cards need free/busy.
The store is the start of Burrow's own calendar.
Outings (concerts, tickets, checklist, search words) and the Evenementen page exist in
Hedwig since 22 Oct (`.agents/wiki/topics/outings.md`); still to come for them: putting
them in the shared calendar.
**Scope:** about five days in four phases, Google first; events and tickets three more.

## Outings: bring bookings together

**What:** (1) merge two outings into one in Hedwig (mails, tickets, checklist and
pictures move along, the other is deleted) and move a linked mail from one outing to
another; (2) parts of an outing: a hotel night, locker, parking, camping spot or train
with their own time, place and booking number, shown under the outing (check-in and
check-out, route to the hotel); (3) Hedwig suggests a part by itself when a booking
mail falls on the outing's dates near its place ("Hotel bij Bosburcht? Voeg toe").
**Why:** a weekend away is one thing for the family, but the hotel booking, the locker
and the tickets arrive as separate mails. Today a locker only joins when Haiku reads the
same event name in it, and a hotel never does.
**Scope:** a merge route plus an `outing_parts` table and Haiku reading hotels and travel
as parts, then the Mac UI (merge from the list, parts on the page); about two days.

## Angela's Mac

**What:** install Hedwig and Pensieve on Angela's Mac (once by hand, then they update
themselves), log in through the browser with her household address, and check her
features under Instellingen › Huishouden.
**Why:** she is the second person of the household; with device login nobody copies a
key.
**Scope:** fifteen minutes with her Mac.

## Back up recordings

**What:** include `<data>/files/` (Pensieve's audio) in the backup, encrypted like the
database, or decide that the iCloud copies from both Macs are the backup.
**Why:** the nightly backup copies only the database; audio of a recording nobody's Mac
mirrored exists only on Dobby's disk.
**Scope:** `infra/dobby/backup.sh` plus the deploy topic; an hour.

## Patronus, the Telegram bot

**What:** a module with a bot token on Dobby: each person links their Telegram account
once with a one-time code from an app; a group chat links to the household. Messages
become tasks for a bot (questions over mail and recordings, "zet melk op de lijst");
task approvals arrive as inline buttons; a morning briefing per person. Design in
`docs/design/burrow-design-system.html` (Patronus screens).
**Why:** Gideon asked for talking to the household's bots from the phone, alone and
together.
One Telegram bot for every persona, not one per persona: Patronus is the channel, each
message says who speaks ("Kreacher: drie mails voor je klaargezet"), so there is one
token, one chat and one group. Telegram is a third party that stores what passes through
it, so Winky never sends content there, at most "er ligt iets gevoeligs voor je klaar in
Hedwig".
Outings: each person's tickets on the morning of the day and deadline reminders with
Doen/Gedaan buttons (`docs/design/hedwig-events.html`, section 4); until then the Mac
shows local notifications, which Patronus then replaces.
**Scope:** design note first (webhook through the tunnel or long polling from Dobby,
linking, which tools a chat may use), then a module; a day.

## Action items to tasks (Remembrall)

**What:** turn the action items in Pensieve's notes, and mail that waits for an answer,
into shared tasks with owner and due date.
**Why:** notes already carry structured actions; nothing follows them up yet.
**Scope:** a module with a task list, the `recording` trigger, a small Mac or web view.

## Sign in with ChatGPT per person

**What:** let each person connect their ChatGPT plan, so agent work for them (notes,
suggestions) runs on their own allowance through the Responses API.
**Why:** both have ChatGPT Plus; today all agent work runs on the CLIs logged in on Dobby.
**Scope:** check eligibility for a self-hosted personal app, then an agent runner that
calls the Responses API with the person's token.

## Household profiles: the rest

**What:** a signature per mailbox and a default sender per role.
**Why:** Gideon and Angela each have private and work or school mail.
**Scope:** server columns and routes plus Hedwig settings; half a day.

## Web interface

**What:** a web app served by the server for settings and an overview of the workers,
logged in through Access (the tunnel check already resolves the person). Give it a name
from the naming topic.
**Why:** settings now need a Mac app; a browser works on any device.
**Scope:** the design system's screens first, then build.

## Invoice routine

**What:** a skill that reads an invoice (fields, PDF attachment), files it and proposes a
line for the bookkeeping, run as a client routine with a server fallback. Needs
attachment download in the providers and a decision about the bookkeeping package.
**Why:** chosen by Gideon as the first household routine; deferred on purpose.
**Scope:** design note first.

## Retire RecHoarder

**What:** after Pensieve imported `iCloud Drive/Meetings` and a few new recordings went
through, remove `~/Applications/RecHoarder.app` and archive `~/git/rechoarder` with a
pointer to Pensieve.
**Why:** two recorders would split the archive.
**Scope:** minutes, Gideon's call.

## Licence

**What:** choose a licence for the public repository (MIT, or AGPL to keep hosted
forks open) and add `LICENSE`.
**Why:** without one, nobody may legally reuse the code, which defeats publishing it.
**Scope:** one file; Gideon decides.

## Full-text index for mail search

**What:** an FTS5 table over subject, sender, recipients and body, kept in step with
`messages`, used by word search and the bot's plans instead of `LIKE`.
**Why:** with the whole archive on Dobby every search scans every body; about 300 ms for
50,000 messages on a MacBook, slower on Dobby and per keystroke.
**Scope:** a migration with triggers, the search query and ranking; half a day. Only once
search feels slow.

## A faster server start

**What:** the server takes 7 to 8 s from `systemctl restart` to answering `/health` on
Dobby; cloudflared answers 502 for that long. About 2.5 s is loading modules (most of it
Node resolving `package.json` files through pnpm's `node_modules`; `dist/cli.js` alone
takes as long), about 1 s more is the rest of a fresh start, and the remaining 3 to 4 s
comes with the real 600 MB database. Profile `dist/main.js` with `--cpu-prof` against a
copy of the database, then consider bundling the dependencies into the tsup build
(better-sqlite3 stays external) and moving slow startup work after `serve`.
**Why:** every deploy is a gap for the apps; they now retry quietly, but agents and MCP
clients still see errors.
**Scope:** an hour to profile, a few hours to fix.

## Pensieve v2: the UI on the new engine

**What:** the screens of `docs/design/pensieve.html` on the engine of
`docs/plans/2026-10-22-pensieve-v2.md`: the gallery with kind and label filters, the
memory view (timeline from segments and marks, transcript following playback, side
panel), the recording stage and pill with Markeer, the floating orb, the dictation HUD
(and switching on `DictationController`), the Verklein video sheet, Settings › Labels
and the Mac settings for video format, size cap and automatic transcripts per kind;
pause; title and labels from the calendar once Burrow has calendars.
**Why:** the engine landed without UI so the design can settle first.
**Scope:** several days; the plan lists what each screen needs.

## Pensieve: speakers across parts and a timestamp model after February 2027

**What:** (1) feed the diarizing model clips of the speakers from part one
(`known_speaker_names[]`, `known_speaker_references[]`) so "A" stays "A" past 20
minutes; (2) choose a transcription model with timestamps before
`gpt-4o-transcribe-diarize` shuts down on 2027-02-26, or align `gpt-transcribe` text
locally.
**Why:** speaker letters restart per part; the only timestamping model is deprecated.
**Scope:** half a day for (1); (2) depends on what OpenAI offers.
