# Mail search

Hedwig searches mail on the server through an FTS5 index, finds people with `@name`, and
searches by meaning in two steps: a bot plans the search from the question alone, the
server runs the plan three ways and fuses the lists, then the bot reads subject and
summary of the best thirty to order them and answer. The design, its principles and the
rejected alternatives are in `docs/design/hedwig-search.html` and
`docs/plans/2026-11-02-hedwig-search.md`. Code: `modules/hedwig/src/server/search.ts`,
`search-text.ts`, `people.ts`, `ai-search.ts`, `vectors.ts`, `embeddings.ts`; on the
Mac `Sources/HedwigCore/Search.swift` and `AppModel+Search.swift`.

## The index

- `message_search` is a contentless FTS5 table (`unicode61 remove_diacritics 2`,
  `contentless_delete=1`) with four columns: subject, people (names and addresses of
  From, To and Cc), body (the first 20,000 characters) and facts (summary, keywords,
  people, organisations, and the names of linked outings). Weights in bm25: 10, 4, 1, 3.
- Its rowid is `message_search_keys.id`, an integer primary key per message: a
  message's own rowid may change on VACUUM.
- Triggers keep it in step (migration 0025): insert, update of subject/from/to/cc/body
  and delete on `messages`; insert and update of the facts; linking and unlinking an
  outing and renaming one. The view `message_search_source` builds a row.
- Building it took 33 s on Dobby for 51,000 messages (79 MB); the install waits up to two
  minutes for a migrating server. A prefix index ('2 3') doubled the size without making
  short prefixes faster; a trigram index for substrings took 221 s and 515 MB.

## Word search

- Every word must match; a word of three letters or more also matches longer words it
  starts (Dutch compounds: "tandarts" finds "Tandartspraktijk"), the word being typed
  from two letters. One letter waits. `"a phrase"` stays whole, `-word` leaves out,
  `@name` is a person.
- Results come best first: bm25 with a little weight for recency (a year-old message
  weighs three quarters). The Mac can sort newest first.
- With three words or more and no mail holding them all (a question typed before Enter)
  the server ranks by the words mail does hold and sets `loose`.
- Each result has `hit`: the piece of the body around the first match with the matched
  words as UTF-16 ranges, unless subject and sender already show every word.
- `total` counts every match, beyond the page.

## People

`mail_contacts` holds every address a mailbox wrote to (`sent`) or heard from
(`received`), kept by triggers on `messages`; the mailbox's own address and spam are
left out. `GET /api/search/people?q=` merges addresses under one name of two words or
more, weighs `3 × sent + received` fading over a year, and offers a whole domain
("@school.example") once several people write from it, never gmail.com and the like.
A person in a search is an FTS phrase on the people column.

## Search by meaning

1. **Plan** (`POST /api/search/ai`): Kreacher's `mail-search` skill sees the question,
   the mailboxes, the chips already in the field and what the person wrote under
   "Over jou, voor zoeken" (`hedwig.searchAbout`), never mail. The plan has word groups
   (alternatives), people, a period, kinds, flags and whether the question wants an
   answer. The response carries the plan and the tokens with keys (`people:0`,
   `period`, `group:1`); the client sends the plan back with `without` to drop a chip,
   and the server reruns it without a bot.
2. **Three passes, fused** with reciprocal rank fusion: every group (with the plan's
   people), any group (without them: a person the bot named is a preference, not a
   filter), and the nearest by meaning when the Mac sent the question's vector. People
   chosen as chips in the field are always a filter. Nothing found drops the plan's
   people, then its period.
3. **Read** (`POST /api/search/ai/rank`): when `hedwig.searchReads` is on, the
   `mail-search-rank` skill reads the best thirty, newest first, as one line each: date,
   who, subject, the facts' summary (or the snippet) and their amounts and dates, with
   secrets and personal numbers replaced; never a body, and a sensitive message only by
   its summary. It returns the fitting ones in order and, when asked, one sentence with
   the mail it rests on. It has no tools; a crafted mail can at most mislead the order
   or the sentence, which the person sees next to its sources.

Both bot calls are `urgent` (they skip the queue of agent runs and have a place of their
own, so a search never waits behind reply suggestions) and `thinking: false`
(`MAX_THINKING_TOKENS=0` for the Claude CLI): on Haiku 4.5 a plan took 14 s with
thinking and 6 s without. Haiku 5.5 thinks regardless and plans in 3.5 to 5 s.

## Vectors

- `hedwig.embed` is a standing kind on the local queue pinned to
  `ollama:embeddinggemma`, priority normal (mail facts always has work and starved it):
  sixty-four messages per task, newest first, for people with `hedwig.facts` on. The
  runner offers the model when Ollama has it and sends the first 256 numbers.
- The text is `title: <subject> | text: <subject>\nVan: <sender>\n<summary or body>`;
  a question is `task: search result | query: <question>`.
- `message_vectors` holds them as float32; `VectorIndex` keeps one model's vectors in
  memory (about 50 MB for 51,000) and scores all of them per question in milliseconds.
- Hedwig embeds the question with Ollama on the Mac, giving up after two seconds; a Mac
  without the model searches without meaning.
- Compared on 160 Haiku-written questions about real mail (12,000 messages):
  embeddinggemma found the mail in the top ten 76% of the time at 76 mails a second,
  qwen3-embedding 0.6b 74% at 41, bge-m3 77% at 43 with 1024 numbers that cannot be cut.

## On the Mac

- The field takes chips (`.searchable(text:tokens:)`): `@` offers people, a month name,
  a year, "vorige week", a kind ("facturen") or "bijlage" offer themselves. A chip
  replaces the words it stood for.
- The open place or Overal is the field's scope bar (`.searchScopes`, shown while
  searching). Above the list, not in it (a list row keeps its first height): order and
  codes, the plan's chips, the answer card, and lenses over the best thirty results
  (people, kinds, attachments, years), as small bordered capsule buttons. Chips and lenses scroll on one line and every text has a
  line limit: a wrapping layout or a fixed-size text there gave the column the height of
  one word per line at width zero, and the window's content shifted up under the toolbar.

## Measuring

The bench scripts that produced the numbers ran on Dobby against a copy of the database
(a script reads it; the hook keeps databases out of an agent's context): known-item
queries from real subjects for word search, and Haiku-written questions for search by
meaning, old against new. See the plan for the results.
