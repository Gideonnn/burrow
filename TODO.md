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
