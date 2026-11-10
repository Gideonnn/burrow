---
id: 2026-11-11-triage-stopped-when-the-claude-login-expired
date: 2026-11-11
kind: incident
area: [hedwig, server, infra]
topics: [triage, architecture, deploy]
---

# Triage stopped when the Claude login expired

**What happened.** The household saw a lot of spam in the inbox. The triage log showed
why: on 2026-11-03 triage stopped. Of the 162 inbox mails from the two weeks before
2026-11-11, 99 were never triaged (98 at the three-attempt limit). The Claude CLI on the
server had lost its login ("OAuth session expired and could not be refreshed"), exiting
1 with an empty stderr, so the log only said `claude exited with 1:`. The Codex fallback
had never worked for triage: the ChatGPT login refuses `gpt-6.1-sol`, and strict
structured output refuses the `oneOf` that zod writes for the action union. The nightly
CLI update check failed for the same login reason and rolled each new version back,
logging "failed the check" as if the version were at fault.

Of the 90 decisions before that, 52 were keeps, 18 of them with `unsure: true`, and 8 spam:
newsletters and marketing from senders never written to, which the old skill told the
bot to keep when unsure. The bot treated one newsletter as spam on one day and as an
unsure keep on another. No rule had ever been learned, and moving mail to spam by hand
was recorded nowhere.

**Fixed.** The runner reports Claude's envelope on a failing exit, Codex runs its own
default model with `anyOf`, and the update check logs the reason. Triage gained sender
rules learned both ways, applied before the bot, and doubts that stay in the inbox (see
the [triage topic](../topics/triage.md)). The Sorting Hat answers spam with `unsure`
instead of keep and names the signals for unsolicited marketing.

**Rejected.**
- A spam rule for the parent domain (`example.com` for `news.example.com`): a shop's or
  platform's account mail shares the parent with its marketing. The exact host is safe;
  a second host costs one more click.
- A not-spam rule that also skips authentication: it would let a forged sender through
  without the bot. Failed SPF, DKIM or DMARC still goes to the bot.
- Learning from moves seen in sync (phone, webmail): Gmail's own filter moves mail the
  same way, and those would become rules nobody made.
- Retrying the untriaged backlog automatically after the login was fixed: a burst of a
  hundred agent runs on old mail the person has partly handled already. Left to a TODO.
