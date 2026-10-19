# Triage

Every new inbox message goes to the triage bot (Kreacher by default, `BURROW_TRIAGE_BOT`)
once. The server runs the bot headless through the agent CLIs logged in on the server
machine, applies the decision at the provider and records it. Code: `modules/hedwig/src/server/triage.ts`. A person can switch it off (`hedwig.triage`).

## One run

1. The prompt holds the owner's instructions, learned rules and server-side facts
   (authentication results, `List-Unsubscribe`, whether the owner ever wrote to the
   sender), then the mail text inside `<untrusted_message>`. A closing tag inside the
   mail is defused so it cannot end the block.
2. `claude -p --model <bot.model> --tools "" --strict-mcp-config --no-session-persistence`
   with the bot's persona and skills as system prompt and the decision schema as
   `--json-schema`. No tools and no MCP: a crafted mail has nothing to call. Codex
   (`codex exec --sandbox read-only --output-schema`) is the fallback (`BURROW_AGENTS`).
3. The answer must parse as `triageDecision`; anything else counts as a failed run.
4. `serverOpsFor` turns the action into provider operations; the message is marked
   triaged only after they succeeded.

Failed runs leave the mail untouched. A sweep every ten minutes retries untriaged inbox
mail from the last two days, at most three attempts per message.

## Review and learning

Spam and archive decisions land in the "Gefilterd" review (`GET /api/filtered`, unsure
first). Confirming removes an entry; restoring reverses the operations at the provider
and adds a learned rule for that sender, which the next prompts include. Instructions,
rules and reviews belong to the mailbox owner; keys of another person never see them.

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
