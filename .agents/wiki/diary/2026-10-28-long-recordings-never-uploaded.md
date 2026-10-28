---
id: 2026-10-28-long-recordings-never-uploaded
date: 2026-10-28
kind: incident
area: [pensieve, server]
topics: [testing]
---

# 2026-10-28 Recordings over about 80 MB never uploaded

A 70-minute call (133 MB WAV) stayed in Pensieve's outbox with "De gegevens konden niet
worden gelezen omdat ze ontbreken", Foundation's text for a `DecodingError.keyNotFound`.
`PUT /api/uploads/:id` answered `{received, size, complete}`, while BurrowKit decodes
every chunk reply as `UploadState`, which requires `id`. Each chunk therefore landed on
the server but counted as a failure; the client recovered the offset with `GET` and went
on, but its failure counter only resets on success, so the fifth 16 MB chunk threw.
Anything under about 80 MB (roughly 40 minutes of 16 kHz mono) arrived, just slowly from
the back-off sleeps, which hid the bug since BurrowKit was written on 2026-10-20.

- **Fix:** the chunk reply carries `id`, so every installed app works again without a
  new build. The server test asserts the reply has the shape `UploadState` decodes.
- **Not lost:** the outbox keeps the audio until the server has the recording.
