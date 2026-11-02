# Hedwig search

Plan and record of 2026-11-02. A strong search is one of the reasons for an own mail
client; Hedwig's was slow (LIKE over every body) and its search by meaning only turned a
question into words. The visual design, with four options worked out against seven
principles, is `docs/design/hedwig-search.html`; the reference for what exists is the
wiki topic `.agents/wiki/topics/search.md`.

## Principles

1. **One field, no screen.** Everything starts and ends in the search field; structure
   (who, when, what kind) appears as chips in it, never as a form.
2. **At once, then smarter.** Results with every keystroke; the bot never blocks, it
   improves the same list when it is done.
3. **Show what was searched.** What Hedwig or the bot made of a question is chips that
   can be dropped. Search by meaning fills in the field for you.
4. **People first.** `@name` is a first-class term: everyone the person mails with, all
   their addresses, mail to someone weighs more than mail from them.
5. **Answer above the list.** A question gets its answer on top, with the mail it comes
   from one click away.
6. **Mail stays untrusted.** The planner sees only the question; what reads mail has no
   tools and may only order and answer briefly; sensitive mail never goes to the cloud
   unredacted.
7. **Yours.** Gideon runs a business, Angela studies: their own words, defaults and
   settings, and mail one shares the other can find.

## Options

- **A, token field**: one field with chips and suggestions; Enter puts the bot's plan in
  chips. Low risk, native, strong on 1 to 4.
- **B, ask Hedwig**: a conversation with answers first and follow-up questions. Strong
  on answers, slow (two bot rounds per question).
- **C, lenses**: above the results a timeline and lenses drawn from what they hold, one
  click to a chip. Strong for gathering a stack (a quarter's invoices).
- **D, dossier**: `@person` alone opens a card of that person or organisation. Strong for
  clients and teachers.

Chosen: A as the base, with B's answer card (one question, one answer, no chat) and C's
lenses (people, kinds, attachments, years over the best thirty). D and B's follow-ups
are in TODO.

## What was built

- Server: the FTS5 index with triggers (migration 0025), word search on it with prefixes,
  phrases, exclusion, `@name` and filters, marked hits, totals, a closest-match fallback
  for typed questions; `mail_contacts` and `/api/search/people`; search by meaning as a
  plan, three fused passes and a reading step with an answer; `hedwig.embed` on the
  Mac's runner; per-person settings `hedwig.searchAbout` and `hedwig.searchReads`;
  searches skip the agent queue and run without thinking.
- Sharing (built alongside, see `.agents/wiki/topics/sharing.md`): share a mail with the
  other person, who can open and find it; Winky suggests household mail, per person off,
  suggest or share by himself, learning per sender.
- Mac: chips in the field with suggestions, the header with plan chips, answer, lenses
  and order, marked hits in the rows; share button, Gedeeld place.

## Measurements

On Dobby, against a copy of the real database (51,397 messages, 182 MB of text).

| | before | after |
|---|---|---|
| a word, server time | 1.1–2.7 s | 2–70 ms |
| one letter | 23 s | waits for two letters |
| "fa" (typing) | 2.7 s | 0.36 s |
| index build | none | 33 s, 79 MB |

Known-item word search (400 real messages; a middle-frequency subject word, plus the
sender's first name): the wanted mail in the top ten 24% and 62% of the time ranked by
bm25, against 4% and 37% newest first.

Embedding models on 160 Haiku-written questions over 12,000 messages, top ten: 
embeddinggemma 76% (76 mails/s), qwen3-embedding 0.6b 74% (41/s), bge-m3 77% (43/s).

Search by meaning, old against new, on 80 of those questions (where the wanted mail
ends up; MRR is the mean of one over its place):

| | top 1 | top 3 | top 10 | in 50 | MRR |
|---|---|---|---|---|---|
| word search, old (LIKE, newest first) | 8% | 18% | 36% | 74% | 0.16 |
| word search, new (index, bm25) | 14% | 29% | 44% | 85% | 0.25 |
| by meaning, old (plan over LIKE) | 11% | 28% | 44% | 59% | 0.22 |
| new plan over the index | 15% | 36% | 48% | 64% | 0.26 |
| plus the nearest by meaning | 19% | 41% | 54% | 68% | 0.31 |
| plus the reading step | 21% | 40% | 55% | (30 read) | 0.33 |

The bot answered 6 of the 7 questions that asked for a fact. Medians on Dobby: the old
plan 7.7 s plus 1.8 s of LIKE; the new plan 6.1 s without thinking, the passes 1.1 s
(0.2 s after the index fixes the same night), the reading step 6.1 s. Caveat: Haiku
wrote the questions from the mails' summaries, which flatters the vectors (made from
the same summaries); 80 questions is a small sample.

## Not built

- D, the person card, and B's follow-up questions; lenses counting over every match
  (TODO).
- Splitting Dutch compounds in a question ("tandartsrekening" finds no mail; the plan
  does split it).
- Kreacher on Haiku 5.5 and without thinking for other kinds (TODO).
