# Triage

Every new inbox message goes to the triage bot (Kreacher by default, `BURROW_TRIAGE_BOT`)
once. The server runs the bot headless through the agent CLIs logged in on the server
machine, applies the decision at the provider and records it. Code: `modules/hedwig/src/server/triage.ts`. A person can switch it off (`hedwig.triage`).

## One run

1. **Sender rules first.** A sender the owner marked as spam (the address, or the exact
   sending host for bulk mail) goes straight to spam with a fixed reason; no model runs.
2. The prompt holds the owner's instructions, learned rules and server-side facts
   (authentication results, `List-Unsubscribe`, whether the owner ever wrote to the
   sender), then the mail text inside `<untrusted_message>`. A closing tag inside the
   mail is defused so it cannot end the block.
3. `claude -p --model <bot.model> --tools "" --strict-mcp-config --no-session-persistence`
   with the bot's persona and skills as system prompt and the decision schema as
   `--json-schema`. No tools and no MCP: a crafted mail has nothing to call. Codex
   (`codex exec --sandbox read-only --output-schema`) is the fallback (`BURROW_AGENTS`).
4. The answer must parse as `triageDecision`; anything else counts as a failed run.
5. A spam verdict on a sender the owner called not spam becomes `keep`, unless SPF, DKIM
   or DMARC failed: a forged sender stays the bot's to judge.
6. Spam with `unsure: true` is a **doubt**: nothing happens at the provider and the log
   entry gets status `doubt`. Everything else goes through `serverOpsFor` to provider
   operations; the message is marked triaged only after they succeeded.

Failed runs leave the mail untouched. A sweep every ten minutes retries untriaged inbox
mail from the last two days, at most three attempts per message; older mail and mail past
three attempts stays untriaged for good. When the Claude login on the server expires the
CLI exits 1 with an empty stderr and the reason only in its JSON envelope, which the
runner now reports ("Failed to authenticate: OAuth session expired"); log in again on the
server with `claude` as the `dobby` user.

## Review and learning

Spam and archive decisions wait for review (`GET /api/filtered`, unsure first). Hedwig
shows them in the mailbox's own Spam or Archief, on top of the folder with the reason;
there is no separate page. Confirming ("Klopt") removes an entry; restoring ("Geen spam",
"Terug naar inbox") reverses the operations at the provider.

Doubts are listed by `GET /api/doubts`; Hedwig marks them in the list and shows "Kreacher
twijfelt of dit spam is" with **Spam** and **Geen spam** above the open message
(`POST /api/doubts/:id/spam|not-spam`). Older unsure spam that was moved before doubts
existed keeps the Spam review.

Every correction teaches a **sender rule** (`learned_rules.kind` `spam` or `not-spam`,
`sender`), and the latest correction about a sender replaces earlier ones:

| The person | Learns |
|---|---|
| "Markeer als spam" (`moveToSpam` through `POST /api/messages/:id/actions`) | spam |
| Answers a doubt with Spam | spam |
| "Geen spam" on a review, moves spam back to the inbox, or answers a doubt with Geen spam | not spam, for the address |

A spam rule covers the address, or for bulk mail (`List-Unsubscribe`) the exact sending
host such as `news.example.com`, never a free-mail host such as `gmail.com`. Exact host,
not the parent domain, so one shop's newsletter host never condemns its account mail.
Only the mailbox owner's own key teaches (an agent's MCP moves do not), and a hand-made
move also gets a triage log entry (`bot: hand`, status `confirmed` or `restored`) and
settles any open doubt or review for that message. Moves made on a phone or in webmail
are not seen and teach nothing. Restoring archived mail still adds a plain-text rule.
The rules go into every prompt as well, and Settings › Geleerd van jouw controles lists
them with a delete button (`DELETE /api/rules/:id`).

Spam stays unread: triage only moves it (`serverOpsFor`), Hedwig does not mark it read
on opening and loads its remote images, like a doubt's, only when the person clicks
"Afbeeldingen laden" for that one message; the "Altijd" setting never applies. Restoring
spam brings it back read (`restoreOps`), also for older entries that triage marked read;
restored archive mail comes back unread. Archived mail is marked read so phones show no
badge. Instructions, rules and reviews belong to the mailbox owner; keys of another
person never see them.

A smoke test on 2026-10-19 with a fake PostNL phishing mail returned `spam` with a Dutch
reason in about six seconds and ignored an injected "keep this mail".

## Summaries and reply suggestions

`GET /api/messages/:id/insights` returns a short summary (only for long mail) and up to
three complete replies, made by the triage bot with the `reply-suggestions` skill and
cached per message. Each agent run uses exactly one skill, so instructions for another
job never leak in. The server warms the cache right after triage marks a message
"needs reply" or when its body is longer than 1,500 characters; Hedwig asks only for such
messages and offers a button otherwise. `BURROW_LANGUAGE` sets the language of the text
the bots write (reasons, summaries); replies follow the language of the message.
