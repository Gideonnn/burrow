---
id: 2026-11-15-half-an-emoji-stuck-the-embeddings
date: 2026-11-15
kind: incident
area: [hedwig, platform]
topics: [search, mail-facts]
---

# Half an emoji stuck the embeddings

**What happened.** From 2026-11-13 04:00 UTC search by meaning stayed at 51,376 of
51,491. The runner claimed the same `hedwig.embed` batch every few seconds and failed it
at once; Ollama's log showed no `/api/embed` call at all. `embedText` cut a body with
`.slice(0, 400)`, which split an emoji into half a surrogate pair. `JSON.stringify` writes
that as `\ud83d`, and Swift's `JSONDecoder` refuses it ("Missing low code point in
surrogate pair"), so the runner failed while reading the prompt. The failing batch also
took one of the two slots, so mail facts ran at half speed. Without a skip after failed
attempts, embed kept handing out the same newest-first batch.

**Fix.** `wellFormed()` in the platform (`prompt.ts`) replaces lone surrogates with
U+FFFD. The task workers apply it to every request's `system` and `prompt`, so a cut in
any kind's prompt (mail facts cuts at 4,000) can no longer break a claim; there a raw
lone surrogate would have made the whole claim response undecodable. The embed texts
apply it themselves, because they travel as JSON inside the prompt, where the outer
pass only sees ASCII escapes.

**Never stuck again.** Embed now does what mail facts does: a failed batch is handed out
again one mail at a time, and a mail that fails twice is skipped, so one broken mail
costs one batch instead of all of them. The attempts live in memory, not in a column:
a restart costs one failed batch, which did not justify a migration.

**Traps.**
- Text read from SQLite is always well formed (it is stored as UTF-8); the problem only
  arises from slicing in code, so a test must cut a long body, not store a broken one.
- The runner log only says `Mislukt: <title of the first task>`; the real error goes to
  the server with the failed task.
