# Mail facts

Per message Hedwig keeps **facts**: category, priority, a short summary, people,
organisations, amounts, dates and search words, plus whether it is **sensitive**
(secrets, BSN, IBAN). Search and agents read the facts instead of the mail. The plan and
the model measurements are in
[the plan](../../../docs/plans/2026-10-20-runners-and-mail-facts.md).

## Three sources, cheapest first

1. **Rules** (`modules/hedwig/src/server/facts/rules.ts`) run on every message that sync
   or backfill stores (`MailService.onStored`), and once over the archive at start
   (`rulesPass`). Secrets in known formats, an IBAN that passes mod-97 and a BSN that
   passes the eleven test near the word BSN set `sensitive` with the kinds found, never
   the values. Login codes and account notices get category `code` or `account` and
   priority `low`. Bump `RULES_VERSION` when a rule changes; every message is checked
   again.
2. **Templates**: automated mail (a noreply-like sender or `List-Unsubscribe`, not
   `Re:`/`Fwd:`) is grouped by sender plus subject pattern ("je pakket # is onderweg").
   A group of three or more becomes a `message_templates` row. The standing kind
   `hedwig.templates` (cloud queue, pinned to `haiku`, Kreacher's `mail-templates`
   skill) sends twenty templates per call, each with at most two non-sensitive examples
   with codes, links and personal numbers replaced. Every member and every new message
   that matches gets the answer.
3. **Winky** (`hedwig.facts`, local queue, pinned to Winky's model, the `mail-facts`
   skill) reads the rest on the owner's Mac through Ollama, newest first: no template,
   no rule category, not spam or trash. Two failed attempts and a message is skipped.

Rules win: a rule category stays, and a model can add `sensitive` (kind `model`) but
never lift it. Only people with the feature `hedwig.facts` ("Mail laten indexeren", off
by default) get templates and Winky; everyone gets the rules.

## Using them

- Every `MessageSummary` carries `facts` (null before the rules ran).
- Word search also matches keywords, summary, people and organisations, and hides
  priority `low` unless `includeLow` ("Toon ook codes"). The bot's search plan has
  `categories` and `includeLow`.
- Everything that goes to a cloud bot (triage, suggestions, routines, MCP `get_message`)
  has secrets and personal numbers replaced by `[iban]`, `[bsn]` or
  `[secret: github-token]`.
- **Facts-only keys** (`factsOnly`, "Alleen feiten" in Hedwig): no `get_message`, no
  message or insights route (403), empty snippets, and search never looks in bodies.

## The runner on the Mac

`burrowctl runner` claims both queues: local tasks on Ollama, cloud tasks on the Mac's
`claude`. Settings live in the defaults suite `app.burrow.runner`
(`burrowctl runner config`, `set key=value`): the local queue by default only between
00:00 and 07:00 and on the charger, `concurrency` 2, model `ollama:gemma4:26b-a4b`.
While it works it keeps the Mac awake; a closed lid without an external display still
sleeps.

```sh
burrowctl runner login                 # browser login; the key has only read and tasks
burrowctl runner install               # launchd agent app.burrow.runner, menu bar icon
burrowctl runner status                # runners and the work waiting
burrowctl runner off | on              # pause on the server
```

A Mac nobody sits at logs in with a key from the server CLI, piped in so it never shows:
`ssh dobby '~/burrow/infra/dobby/cli.sh create-key <name> "Runner op <Mac>" read,tasks' | grep -o 'bk_[A-Za-z0-9_-]*' | burrowctl runner login <url> --token-stdin`.

## Traps

- **The keychain asks again after every rebuild.** `burrowctl` is ad-hoc signed, so a
  new build is a new app to the keychain and `runner run` blocks on an invisible prompt.
  After installing a new build, log in again (the old key can be revoked in Hedwig).
- The Ollama app (`brew install --cask ollama-app`), not the Homebrew formula: only the
  app's MLX runner has structured output. Ollama does not show the schema to the model,
  so the skill lists every category.
