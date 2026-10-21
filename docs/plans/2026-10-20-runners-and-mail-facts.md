# Runners, two queues and mail facts from a local model

Plan of 2026-10-20, built on 2026-10-22 (phases 1 to 7; see "What was built" at the end
and the [mail facts topic](../../.agents/wiki/topics/mail-facts.md)). Decisions agreed with
Gideon are marked **(agreed)**.

Every machine that does agent work registers itself as a **runner** and works off a
queue. There are two queues: a **local** queue for work on raw, possibly sensitive
content, only for runners whose model runs on the owner's own device, and a **cloud**
queue for work that may go to a cloud AI (Claude, Codex), which Dobby and the Macs serve.
Tasks carry a priority and may pin the model that runs them.

The first work is **mail facts**: category, priority, a short summary, names, amounts,
dates and search words per message. Fixed rules on the server flag secrets, personal
numbers and login codes. Mail that repeats (codes, shipping updates, newsletters) is
grouped into templates that Haiku indexes once per template; a model on Gideon's Mac
reads the rest at night. Claude and Codex then search and read the facts instead of the
mail.

## Names **(agreed)**

- **Dobby** is the host: the home machine running the server and the cloud runner.
- **Kreacher** does the chores that may use a cloud AI (Claude, Codex, Haiku templates).
- **Winky** does the sensitive chores: the bot on the local queue, run by the local model
  on the owner's Mac. Mail facts are her first work.
- **Sorting Hat** answers questions with fixed options (category, priority, sensitive, the
  triage action). Today it is Kreacher's triage skill; a small local decision model in
  the style of Jev (a model that picks between given options with a probability instead
  of writing text) can take it over. Jev itself is hosted by TypeSafe and would send mail
  to a new third party, so only local models of that kind (Laya, Strands Decider) qualify.
- The runner and the queues are mechanisms and keep plain names.

## Goals

- Search finds mail by meaning ("tv" finds "televisie", "de bestelling bij HelloTV").
- Secrets (API keys, private keys) and personal numbers (BSN, IBAN) in mail are flagged
  and never reach a cloud AI **(agreed)**.
- Login codes, password resets and similar noise drop out of search by default.
- Claude and Codex can answer "wanneer kwam die factuur van de tandarts" from facts,
  with a key that cannot read message bodies at all.
- Work on raw content can be kept on the owner's own Mac; any runner, local or cloud,
  joins by registering, without server changes.
- The Mac's runner is a background job that is quick to switch on and off **(agreed)**.
- Only Gideon's mail gets model facts; Angela's mail gets the rules only **(agreed)**.

## Why the Mac and not Dobby

Dobby is a Celeron N3450 (4 cores, 7.6 GB RAM, no GPU). A small language model there
takes an estimated 20 to 60 seconds per message, so the archive would take weeks of
full load. Gideon's MacBook (M2 Max, 96 GB) runs a mid-size model at a few seconds per
message. Dobby keeps the cheap, deterministic part: the rules.

## Runners

A runner is a process that claims tasks, runs them and reports back. Today there are two
kinds, hard-wired: the server's pool and the Hedwig app's `LocalRunner` (which runs
`routine` tasks with the Mac's `claude`). They become one mechanism.

- **Registration.** A runner announces itself with its key (`POST /api/runners`): a
  name ("MacBook van Gideon"), the queues it serves, its agents and models
  (`claude`, `codex`, `ollama:<model>`), the task kinds it knows and how many it runs at
  once. It sends a heartbeat with each claim; a runner silent for five minutes shows as
  offline. The server's pool registers itself the same way at startup, as the runner
  `dobby` on the cloud queue.
- **Who it works for.** Local work: only the person of the runner's key. Cloud work: also
  the other people of the household who allow it **(agreed)**. Each person has the
  setting "Mijn cloudtaken mogen ook op andere Macs in huis draaien", off by default and
  only changeable by that person (not by an admin), because their redacted mail then
  passes through someone else's Mac. The server's runner works for everyone, as now.
- **Pausing.** A runner can be paused, from the runner itself or from the server's list.
  A paused runner claims nothing and finishes what it holds.
- **Visible.** Instellingen › Runners lists every runner of the household: online, paused,
  which queues, what it is doing now, and how much work waits per queue.

## Two queues

A task kind declares its queue; a task inherits it.

| Queue | What it may contain | Who may claim it |
|---|---|---|
| `local` | Raw content, including sensitive mail; bodies unredacted | A runner of the task's person, with a model on that same device (Ollama), never Dobby |
| `cloud` | Content with secrets and personal numbers redacted | Any runner on the cloud queue that works for the task's person, Dobby included |

- A local task never falls back to the cloud. If no local runner is around, it waits.
- A runner with a local model also takes cloud tasks when they wait **(agreed)**: an
  unpinned cloud task of a kind that allows a small model (`localModelOk`), queued for
  more than ten minutes. Local is always at least as private, so this only trades
  quality for speed, and the kind decides whether that trade is acceptable.
- Agent work about a sensitive message (a summary, reply suggestions) moves to the local
  queue if a local runner is registered, else it runs in the cloud on the redacted body.
- The existing `where: server | client` and `fallbackAfterHours` become "cloud queue,
  preferring a Mac runner, with Dobby taking over after the fallback". Migration keeps
  current routines working.

### Priority and a pinned model

- **Priority.** Every task has `priority`: `urgent` (a person waits for it: search,
  reply suggestions), `high` (triage of new mail), `normal` (routines, templates) or
  `low` (indexing the archive). A runner claims the highest priority first, oldest first
  within it. The kind sets the default; a routine or the caller may change it. Standing
  work has a priority too, so new mail always goes before the archive.
- **Pinned model.** A task may pin `model`, for example `claude-haiku-5-5` or
  `ollama:<model>`. A runner claims only pinned tasks whose model it offers; an unpinned
  task runs on the runner's default for that queue (for a bot: the model in its persona).
  A pin is how cheap bulk work stays on a fast, small model and hard work on a big one.
- **Batches.** A kind may say how many items fit in one request (`batchSize`). Starting
  the `claude` CLI costs seconds per call, so twenty small templates in one call is far
  cheaper than twenty calls.

### Standing work instead of a row per message

Indexing 50,000 messages as 50,000 task rows would swamp the queue. A kind may instead
offer **standing work**: on a claim the module hands out the next batch of what is still
missing (here: messages without current facts), and the batch result is stored directly.
The queue shows one line per person ("Mail-facts: 35.600 te gaan"). A runner that stops
halfway loses nothing: the next claim starts with what is still missing.

## The Mac runner: a background job with a menu bar switch

- **Process.** `burrowctl runner`, started by launchd as a user agent, so no app needs to
  stay open **(agreed)**. A Burrow app installs it once through `SMAppService` (macOS's
  way to register a login item or agent), or `burrowctl runner install`.
- **Switch.** A small menu bar icon from the runner itself: on or paused, "alleen 's
  nachts aan de lader", per queue (lokaal, cloud), and what it is doing ("Mail-facts:
  12.400 van 48.000"). The same from the command line, so agents can use it:
  `burrowctl runner on | off | status`.
- **When.** Local work by default only on the charger inside a night window (00:00 to
  07:00, a setting); cloud work whenever it is on. While working it holds a sleep
  assertion; a closed lid without an external display still sleeps, so the lid stays
  open at night.
- **Agents.** `claude` for cloud tasks (taking over from Hedwig's `LocalRunner`, which
  goes away), Ollama for local tasks **(agreed)**.
- **Name.** Infrastructure, so a plain name: the runner, no Harry Potter name.

## Mail facts

### 1. Rules on the server, for every message

Run in `MailService` when a message is stored (sync and backfill), before triage, and
once over the existing archive, for both people. Pure code, versioned (`rulesVersion`),
so a rule change re-runs them.

- **Secrets.** Known formats: `sk-…` and `sk-ant-…`, `ghp_…`/`gho_…`/`github_pat_…`,
  `AKIA…` (AWS), `xox[abprs]-…` (Slack), `sk_live_…` (Stripe), `AIza…` (Google),
  `-----BEGIN … PRIVATE KEY-----`.
- **Personal numbers** **(agreed)**. A BSN (nine digits passing the eleven test, near
  "BSN" or "burgerservicenummer") and an IBAN (passing the mod-97 check).
- A hit sets `sensitive` and records the kinds found, never the value. For the cloud
  queue and MCP the value is replaced by `[secret: github-token]` or `[iban]`. A payment
  suggestion that needs the IBAN is therefore local work.
- **Codes and account noise.** Subject and opening lines in Dutch and English
  ("verificatiecode", "inlogcode", "your code is", "reset your password", "wachtwoord
  opnieuw instellen", "new sign-in") together with a short number or a `noreply` sender.
  Sets category `code` or `account` and priority `low`.

Rules decide `sensitive`; the model can add it but never remove it, so a message cannot
talk its way out of the flag.

### 2. Templates: one answer for mail that repeats

Much of an archive is the same mail over and over: login codes, shipping updates,
newsletters, receipts from one shop. Those are indexed once per pattern, not once per
message.

- **Grouping.** Per person, the key is the sender address plus the subject with numbers,
  dates, amounts and codes replaced by placeholders ("Je verificatiecode is 482913"
  becomes "Je verificatiecode is #"). A group is a template when it has at least three
  messages and looks automated: a `noreply` sender, a `List-Unsubscribe` or
  `Auto-Submitted` header, and no replies (`Re:`, `In-Reply-To`). Mail between people is
  never templated.
- **One cloud task per batch of templates.** Kind `hedwig.templates` on the cloud queue,
  priority `normal`, pinned to `claude-haiku-5-5`, twenty templates per request. Each
  template sends the sender, the subject pattern and the redacted body of at most two
  non-sensitive examples, with codes replaced by `[code]`. The answer is category,
  priority, keywords and a summary pattern ("Inlogcode van Netflix").
- **Applied to every member**, and from then on to new mail that matches the template,
  at sync, without any model. Dates and amounts per message come from the rules.
- **Effect (estimate).** If half of the archive falls into a few thousand templates, the
  local model has half the mail to read and Haiku handles the rest in a few hundred calls.
  Phase 0 counts this on Gideon's real archive.

### 3. The model on the Mac, for the rest

A standing-work kind `hedwig.facts` on the local queue, for people with the feature
`hedwig.facts` on (Gideon only).

- **Model.** Through Ollama: an HTTP API on `localhost:11434` with answers constrained to
  a JSON schema **(agreed)**. Candidates: a 7 to 14B model or a small mixture of experts
  of the current Qwen or Gemma family; phase 0 picks one.
- **Input.** Sender, recipients, subject, date and the first ~4,000 characters of the
  text body with quoted replies stripped. No attachments in the first version.
- **What.** Only mail no template covers: personal mail, one-off mail, and every
  sensitive message (which never goes to the cloud). Newest first, priority `low`.
- **Throughput (estimate, measured in phase 0).** About 3 to 8 seconds per message one
  at a time, two to four times faster with parallel requests. 25,000 messages left after
  templates is then roughly one to two weeks of nights; new mail is indexed the next
  night.

### Stored facts

A table `message_facts` in the Hedwig schema, one row per message, cascade on delete:

| Column | Source | Notes |
|---|---|---|
| `sensitive`, `sensitiveKinds` | rules (model may add) | kinds like `github-token`, `iban`; no values |
| `category` | rules or model | enum: `personal`, `work`, `school`, `order`, `shipping`, `invoice`, `bank`, `travel`, `appointment`, `government`, `health`, `newsletter`, `promotion`, `notification`, `account`, `code`, `other` |
| `priority` | rules or model | `low`, `normal`, `high` |
| `summary` | model | at most 200 characters, in the person's language |
| `people`, `organisations` | model | short strings, at most 10 each |
| `amounts` | model | `{ value, currency }`, at most 5 |
| `dates` | model | ISO dates mentioned (due date, appointment, delivery) |
| `keywords` | model | at most 15 search words, synonyms in Dutch and English |
| `templateId` | server | set when the facts come from a template |
| `rulesVersion`, `model`, `modelVersion`, `indexedAt` | server | re-index when a version changes |

Templates live in `message_templates` (person, sender, subject pattern, the template's
facts, model, version, member count). Changing a template's facts updates its members.

The server enforces every limit with zod; an answer that does not fit is dropped and the
message is retried once.

### Using the facts

- **Word search** (`searchMessages`) also matches `keywords`, `summary`, `people` and
  `organisations`, ranked below a hit in the subject. If search gets slow, the FTS5 entry
  in `TODO.md` indexes these columns too.
- **Low priority is hidden by default** from search results (not from the inbox). The
  search header gets "Toon ook codes"; the bot's search plan gets `includeLow` for
  questions like "die inlogcode van Netflix".
- **The search plan** gets an optional `categories` filter ("facturen" becomes
  `invoice`).
- **The app** shows the category as a small tag and the summary under the subject, and a
  lock on sensitive mail. The person always sees the full mail.
- **MCP.** `search_messages` returns the facts with each result; `get_message` returns
  the redacted body. A new key option `facts only` removes `get_message` and returns no
  snippet, so an agent with that key works from facts alone.

## Security

- Mail is untrusted, so the facts are too. The local model has no tools and answers only
  in the schema; enums and short capped fields leave little room for a planted
  instruction. MCP output marks facts as "derived from the message, untrusted".
- The worst a malicious mail can do is mislabel itself: wrong category, a misleading
  summary, or low priority to hide from search. It cannot lower `sensitive`, and the mail
  stays in the inbox and is found with "Toon ook codes".
- A template's answer applies to all its members, so a planted instruction in an example
  could mislabel a whole group. Examples are therefore only automated, non-sensitive
  mail, and a template's facts show in the app with a way to correct them.
- The local queue is enforced on the server: a claim for a local task needs a device key
  of the task's person and a runner registered with a local model. A runner can lie about
  being local, but only with that person's own key, on mail that person can read anyway.
- Content stays private: local work only ever reaches the person's own runner, and cloud
  work (redacted) reaches another person's Mac only after the owner allowed it.
- Secret values are never stored outside the message itself, and never logged.

## Phases

0. **Measure** (half a day). A local script runs two or three candidate models through
   Ollama over 200 of Gideon's own messages: seconds per message, and a quick read of the
   facts. It also counts how much of the archive falls into templates. Real mail and
   results stay on the Mac, never in the repo; tests use invented fixtures.
1. **Rules** (a day). `message_facts` with the rule columns, the detectors with tests,
   redaction for the cloud queue, triage and MCP, the one-time pass over the archive, low
   priority hidden in search. Useful on its own, without any model.
2. **Runners and queues** (two days). Registration, heartbeat and pause; `queue`,
   `priority`, a pinned `model` and `batchSize` on kinds and tasks, with the migration
   from `where`; Dobby's pool as a runner; Instellingen › Runners.
3. **The Mac runner** (one to two days). `burrowctl runner` under launchd with the menu
   bar switch, the night and charger rules and the sleep assertion; it takes over cloud
   tasks from Hedwig's `LocalRunner`, which is removed.
4. **Templates** (a day). Grouping, `message_templates`, the `hedwig.templates` kind on
   Haiku, applying facts to members and to new mail at sync.
5. **Facts** (one to two days). Standing work in the queue, the `hedwig.facts` kind and
   feature, the Ollama agent in the runner, progress in the runner menu and settings.
6. **Search on facts** (a day). Word search and ranking, `categories` and `includeLow` in
   the plan and the mail-search skill, tag and summary in the app, facts in MCP.
7. **Facts-only keys** (half a day). The key option and its check in MCP.
8. **Later, optional.** Embeddings (numbers that capture what a text means) from a small
   local model, for search by meaning without a bot call; attachments (PDF text); other
   cloud runners (a VPS, a second Mac).

## Phase 0 results (2026-10-20)

Measured on Gideon's MacBook (M2 Max, 96 GB) with the Ollama app, over the 97 messages of
one Gmail mailbox that Opus 5.5 labelled as the answer key. The archive was not on Dobby
yet, so this is inbox mail only.

| Model | Seconds per message | Category = Opus | Priority = Opus | Codes low | IBAN flagged |
|---|---|---|---|---|---|
| gemma4:26b-a4b | 5.1 | 82% | 80% | 3/3 | yes |
| gemma4:12b | 10.0 | 78% | 79% | 1/3 | no |
| qwen3.6:35b-a3b | 4.7 | 77% | 81% | 3/3 | no |
| qwen3.5:9b | 7.4 | 76% | 79% | 1/3 | no |
| qwen3.8:27b | 20.2 | 72% | 78% | 2/3 | no |
| gemma4:e4b | 3.9 | 71% | 77% | 1/3 | no |

- **Winky runs gemma4:26b-a4b.** Best categories, the only one to flag the IBAN, every
  summary in Dutch. Most disagreements with Opus are borderline (promotion or newsletter,
  other or personal). It flags a few more messages as sensitive than the rules do, which
  only keeps them local.
- **Four requests at a time barely help** (about 15%): the MLX runner works mostly one
  request at a time. Plan on 5 seconds per message: about 12,000 messages a night.
- **Templates on sender plus subject cover less than hoped:** 69% of the mail is
  automated, but only 19% falls into such templates, while 54% comes from senders with
  three or more messages. Newsletters change their subject every time. Group by sender
  for category and priority, and keep per-message facts for the summary and keywords.
- **Haiku on templates:** 5 templates in one call took 15 seconds for $0.004.
- **The rules** found 1 IBAN, 4 codes and 3 account messages in 198 messages. A forwarded
  conversation passed the "automated" test, so `Fwd:` is excluded from templates.
- Traps (Homebrew's Ollama without structured output, the schema not shown to the model)
  are in the diary of 2026-10-20.

## What was built (2026-10-22)

Phases 1 to 7, deployed the same night. Where it differs from the plan above:

- Runners register on their first claim; there is no separate `POST /api/runners`. The
  server's pool is the runner `server`. `GET /api/runners`, `PATCH` and `DELETE
  /api/runners/:id` list, pause and remove them.
- `where` stays: Dobby takes `server` tasks, Macs take `client` tasks of the cloud queue.
- Templates group by sender plus subject pattern only; grouping by sender (phase 0's
  advice) is not done.
- Agent work about a sensitive message is not moved to the local queue; cloud bots get
  the redacted body. Idle cloud tasks on a local model are not built (see `TODO.md`).
- The menu bar icon belongs to `burrowctl runner run` under launchd; Hedwig's own runner
  is gone and its settings show the Mac's runner instead.

## Open questions

None at the moment. Meeting notes stay in the cloud, written by Kreacher on Opus
**(agreed)**.
