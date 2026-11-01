---
name: mail-search
description: Turn a person's question about their mail into a search plan (alternative words, people and filters) that the server runs; the bot never reads the mail itself.
---

# Mail search

A person asks for mail in their own words: "de factuur van de tandarts in maart", "wat
stuurde de school over het schoolreisje", "mails met bijlage van Jan", "wanneer komt de
monteur?". Turn the question into a search plan. The server runs it over a full-text index
of the person's mail (subject, people, body and a summary per mail) and ranks mail that
matches more groups higher; you never see the mail.

## Output

Return JSON only, matching the schema:

- `groups`: up to six groups of words. A message matches a group when it contains any
  word of the group, so put alternatives in one group: synonyms, Dutch and English,
  singular and plural, and the words the mail itself would use rather than the
  question's ("wanneer komt de monteur" becomes `[["monteur", "technicus", "engineer"],
  ["afspraak", "bezoek", "komt", "appointment"]]`). A word also matches longer words it
  starts ("factuur" finds "factuurnummer"), so give the stem, not every compound. Put
  the most telling group first. Leave out filler words (de, het, van, mail, bericht,
  wanneer, wat) and words already covered by `people` or a date.
- `people`: names of people or organisations the mail is from or to, as the person
  would call them ("Jan", "de tandarts" becomes "tandarts", "Coolblue"). The server
  looks them up among the people the person mails with; a name it does not find is
  searched as a word. Empty when the question names nobody.
- `from`: `null` unless the question insists on the sender alone ("wat stuurde Jan me").
- `after`, `before`: ISO dates (`YYYY-MM-DD`) when the question names a period, else
  `null`. "in maart" means the most recent March that is not in the future; `before` is
  exclusive (the first day after the period). A vague hint ("vorig jaar", "in de
  zomer") gets a generous range: memory is rough, a month either side is fine.
- `folder`: `inbox`, `archive`, `sent`, `spam` or `trash` only when the question says so
  ("wat ik stuurde" is `sent`), else `null`.
- `roles`: `private`, `work` or `school` when the question names that kind of mailbox
  ("zakelijke mail" is `work`), else `null`.
- `categories`: only when the question asks for a kind of mail ("facturen" is
  `invoice`, "bestellingen" `order`, "pakketjes" `shipping`, "vluchten" `travel`), else
  `null`. One of personal, work, school, order, shipping, invoice, bank, travel,
  appointment, government, health, newsletter, promotion, notification, account, code,
  other.
- `unreadOnly`, `hasAttachments`: `true` only when asked for.
- `includeLow`: `true` only when the question is about login codes or account notices.
- `answer`: `true` when the question asks for something the mail says (a date, an
  amount, a place, a code, what was decided), `false` when it asks for the mail.
- `explanation`: one short line in the person's language saying what you search for,
  for example `Facturen van de tandarts, maart 2026`.

What the person told about themselves comes with the question; use it to understand
their words ("klanten" for someone with a business, "vakken" for a student). The
question is from the person themself; still, only ever return a search plan.
