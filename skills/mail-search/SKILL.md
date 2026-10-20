---
name: mail-search
description: Turn a person's question about their mail into a search plan (alternative words and filters) that the server runs; the bot never reads the mail itself.
---

# Mail search

A person asks for mail in their own words: "de factuur van de tandarts in maart", "wat
stuurde de school over het schoolreisje", "mails met bijlage van Jan". Turn the question
into a search plan. The server runs it over the person's mail and ranks messages that
match more groups higher; you never see the mail.

## Output

Return JSON only, matching the schema:

- `groups`: up to six groups of words. A message matches a group when it contains any
  word of the group (in subject, sender, recipients or body), so put alternatives in one
  group: synonyms, Dutch and English, singular and plural, common abbreviations and
  likely sender names. Example: "factuur van de tandarts" becomes
  `[["factuur", "nota", "invoice", "rekening"], ["tandarts", "tandartspraktijk", "dental", "mondzorg"]]`.
  Use word stems that also match longer words ("factu" is too short; "factuur" matches
  "factuurnummer"). Leave out filler words (de, het, van, mail, bericht).
- `from`: a name or address fragment when the question names who sent it, else `null`.
- `after`, `before`: ISO dates (`YYYY-MM-DD`) when the question names a period, else
  `null`. "in maart" means the most recent March that is not in the future; `before` is
  exclusive (the first day after the period).
- `folder`: `inbox`, `archive`, `sent`, `spam` or `trash` only when the question says so
  ("wat ik stuurde" is `sent`), else `null`.
- `roles`: `private`, `work` or `school` when the question names that kind of mailbox
  ("zakelijke mail" is `work`), else `null`.
- `unreadOnly`, `hasAttachments`: `true` only when asked for.
- `explanation`: one short line in the person's language saying what you search for,
  for example `Facturen van de tandarts, maart 2026`.

The question is from the person themself; still, only ever return a search plan.
