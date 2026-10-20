# Mail facts: a local model indexes the archive

Plan of 2026-10-20, not built yet. A model on Gideon's Mac reads each message at night
and stores a few facts about it on the server: category, priority, a short summary,
names, amounts, dates and search words. Fixed rules on the server flag secrets and login
codes. Claude and Codex then search and read the facts instead of the mail.

## Goals

- Search finds mail by meaning ("tv" finds "televisie", "de bestelling bij HelloTV").
- Mail with a secret in it (an API key, a private key) is flagged; agents never see the
  secret.
- Login codes, password resets and similar noise drop out of search by default.
- Claude and Codex can answer "wanneer kwam die factuur van de tandarts" from facts,
  with a key that cannot read message bodies at all.
- No mail leaves the household for indexing: the model runs on a Mac of the owner.

## Why the Mac and not Dobby

Dobby is a Celeron N3450 (4 cores, 7.6 GB RAM, no GPU). A small language model there
takes an estimated 20 to 60 seconds per message, so the archive would take weeks of
full load. Gideon's MacBook (M2 Max, 96 GB) runs a mid-size model at a few seconds per
message. Dobby keeps the cheap, deterministic part: the rules.

## Two layers

### 1. Rules on the server, for every message

Run in `MailService` when a message is stored (sync and backfill), before triage, and
once over the existing archive. Pure code, versioned (`rulesVersion`), so a rule change
re-runs them.

- **Secrets.** Known formats: `sk-…` and `sk-ant-…`, `ghp_…`/`gho_…`/`github_pat_…`,
  `AKIA…` (AWS), `xox[abprs]-…` (Slack), `sk_live_…` (Stripe), `AIza…` (Google),
  `-----BEGIN … PRIVATE KEY-----`. A hit sets `sensitive` and records the kinds found,
  never the secret itself.
- **Codes and account noise.** Subject and opening lines in Dutch and English
  ("verificatiecode", "inlogcode", "your code is", "reset your password", "wachtwoord
  opnieuw instellen", "new sign-in") together with a short number or a `noreply` sender.
  Sets category `code` or `account` and priority `low`.

Rules decide `sensitive`; the model can add it but never remove it, so a message cannot
talk its way out of the flag. A message that triggers no rule gets no rule facts.

### 2. The model on the Mac, for meaning

The Hedwig app on the owner's Mac pulls messages without model facts in batches, sends
each to a local model and posts the answer back. The server validates it.

- **Model.** Through Ollama (one install, an HTTP API on `localhost:11434`, answers
  constrained to a JSON schema). Candidates: a 7 to 14B model or a small mixture of
  experts of the current Qwen or Gemma family; phase 0 picks one.
- **Input.** Sender, recipients, subject, date and the first ~4,000 characters of the
  text body with quoted replies stripped. No attachments in the first version.
- **When.** Only while the Mac is on the charger, inside a night window (default
  00:00 to 07:00, a setting), newest mail first. A sleep assertion keeps the Mac awake
  while it works; a closed lid without an external display still sleeps, so the lid
  stays open.
- **Throughput (estimate, measured in phase 0).** About 3 to 8 seconds per message one
  at a time, two to four times faster with parallel requests. 50,000 messages is then
  roughly one to three weeks of nights. Mail that the rules already marked `code` is
  skipped, and new mail is indexed the next night.

## Stored facts

A table `message_facts` in the Hedwig schema, one row per message, cascade on delete:

| Column | Source | Notes |
|---|---|---|
| `sensitive`, `secretKinds` | rules (model may add) | kinds like `github-token`, no values |
| `category` | rules or model | enum: `personal`, `work`, `school`, `order`, `shipping`, `invoice`, `bank`, `travel`, `appointment`, `government`, `health`, `newsletter`, `promotion`, `notification`, `account`, `code`, `other` |
| `priority` | rules or model | `low`, `normal`, `high` |
| `summary` | model | at most 200 characters, in the person's language |
| `people`, `organisations` | model | short strings, at most 10 each |
| `amounts` | model | `{ value, currency }`, at most 5 |
| `dates` | model | ISO dates mentioned (due date, appointment, delivery) |
| `keywords` | model | at most 15 search words, synonyms in Dutch and English |
| `rulesVersion`, `model`, `modelVersion`, `indexedAt` | server | re-index when a version changes |

The server enforces every limit with zod; an answer that does not fit is dropped and the
message is retried once.

## Using the facts

- **Word search** (`searchMessages`) also matches `keywords`, `summary`, `people` and
  `organisations`, ranked below a hit in the subject. If search gets slow, the FTS5 entry
  in `TODO.md` indexes these columns too.
- **Low priority is hidden by default** from search results (not from the inbox). The
  search header gets "Toon ook codes"; the bot's search plan gets `includeLow` for
  questions like "die inlogcode van Netflix".
- **The search plan** gets an optional `categories` filter ("facturen" becomes
  `invoice`).
- **The app** shows the category as a small tag and the summary under the subject, and a
  lock on sensitive mail.
- **MCP.** `search_messages` returns the facts with each result. A new key option
  `facts only` removes `get_message` and returns no snippet, so an agent with that key
  works from facts alone. For sensitive mail, `get_message` (and every bot prompt,
  including triage) gets the body with each secret replaced by `[secret: github-token]`.
  The person always sees the full mail in the app.

## API

Hedwig routes, for the owner's device key with `organize` (the facts change what agents
see, so `read` is not enough):

- `GET /api/hedwig/facts/pending?limit=20`: the owner's messages without current model
  facts, newest first, with the input described above. Only the owner's own mailboxes;
  a shared mailbox is indexed by its owner.
- `POST /api/hedwig/facts`: `[{ messageId, facts }]`; validated, then stored.

Not platform tasks: one task row per message would put tens of thousands of rows in the
queue, and these runs do not go through `claude`. A Mac that stops halfway loses nothing;
the next batch simply starts with what is still missing.

## Security

- Mail is untrusted, so the facts are too. The local model has no tools and answers only
  in the schema; enums and short capped fields leave little room for a planted
  instruction. MCP output marks facts as "derived from the message, untrusted".
- The worst a malicious mail can do is mislabel itself: wrong category, a misleading
  summary, or low priority to hide from search. It cannot lower `sensitive`, and the mail
  stays in the inbox and is found with "Toon ook codes".
- Content stays private: each person's mail is indexed only on their own Mac. Angela's
  mail is never sent to Gideon's Mac, and vice versa.
- Secret values are never stored outside the message itself, and never logged.

## Phases

0. **Measure** (half a day). A local script runs two or three candidate models over 200
   of Gideon's own messages: seconds per message, and a quick read of the facts. Real
   mail and results stay on the Mac, never in the repo; tests use invented fixtures.
1. **Rules** (a day). `message_facts` with the rule columns, the detectors with tests,
   redaction for bots and MCP, the one-time pass over the archive, low priority hidden in
   search. Useful on its own, without any model.
2. **Indexer** (one to two days). The two routes, `MailIndexer` in HedwigCore (Ollama
   client, night window, charger check, sleep assertion), settings for model and window,
   progress in Instellingen ("12.400 van 48.000 berichten").
3. **Search on facts** (a day). Word search and ranking, `categories` and `includeLow` in
   the plan and the mail-search skill, tag and summary in the app, facts in MCP.
4. **Facts-only keys** (half a day). The key option and its check in MCP.
5. **Later, optional.** Embeddings (numbers that capture what a text means) from a small
   local model, for search by meaning without a bot call; attachments (PDF text).

## Open questions

- Ollama or MLX: MLX is faster on Apple chips, Ollama is simpler to install and call.
  Recommendation: Ollama, revisit if phase 0 is too slow.
- Should the Hedwig app run the indexer, or a background `burrowctl index` job started
  by launchd, so the app need not stay open at night?
- Is personal data such as a BSN or IBAN also `sensitive`, or only secrets?
- Does Angela want this on her Mac at all?
