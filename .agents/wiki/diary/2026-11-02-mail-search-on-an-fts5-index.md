---
id: 2026-11-02-mail-search-on-an-fts5-index
date: 2026-11-02
kind: decision
area: [hedwig, server, apps]
topics: [search]
---

# Mail search on an FTS5 index, with people, vectors and a reading step

Word search scanned every body with LIKE: on Dobby 1 to 2.7 s per word over 51,000
messages, 23 s for one letter, newest first. Known-item tests (a word from a real
subject, with or without the sender's first name) put the wanted mail in the top ten
24% and 62% of the time with bm25, against 4% and 37% for newest first.

Decided: a contentless FTS5 table with a separate integer key per message (rowids can
change on VACUUM), kept by triggers, bm25 with subject weighed most and a little
recency, every word of three letters or more as a prefix for Dutch compounds. People
from a contacts table kept by triggers. Search by meaning in two steps: a plan from the
question alone, run three ways and fused, then a reading step over the best thirty that
may answer; chips show the plan and drop parts of it without a new plan.

Rejected: a trigram index (substrings, 221 s and 515 MB to build, against 22 s and
79 MB); a prefix index (twice the size, no faster for short prefixes); embeddings on
OpenAI (all mail to a third party) or on Dobby's CPU (Gideon chose the Mac's runner);
bge-m3 (a hair better than embeddinggemma, half the speed, four times the memory); a
filter screen; a chat for follow-up questions (two bot rounds per turn, see the design).

The bot plans without seeing mail, as before; the reading step does see summaries and
subjects, redacted, with no tools, behind a per-person setting.
