# Pensieve

Pensieve records a conversation on the Mac (your microphone plus whatever the Mac plays,
so both sides of a Zoom or Teams call), and the server turns it into a compressed
recording, a transcript and notes. It replaced RecHoarder (`~/git/rechoarder`), whose
capture code lives on in `apps/pensieve-mac/Sources/PensieveCapture`.

## The pipeline

1. **Record** in Pensieve.app: a private aggregate device of the chosen microphone and a
   Core Audio process tap (macOS 14.2+), mixed to a 16 kHz mono WAV in
   `~/Library/Application Support/Pensieve/Outbox`. Nothing leaves the Mac until Stop.
2. **Upload** in 16 MB chunks (`POST /api/uploads`, `PUT …?offset=`); an interrupted
   upload resumes, and a recording waits in the outbox until the server has it.
3. **Compress** (task `pensieve.compress`, server): ffmpeg to AAC, mono, 16 kHz,
   32 kbit/s, about 14 MB an hour instead of 115 MB; the WAV is deleted.
4. **Transcribe** (`pensieve.transcribe`): split into 20-minute parts (OpenAI caps
   1400 s and 25 MB), `gpt-4o-transcribe` (or the diarizing model with speaker labels
   when `pensieve.speakers` is on), language from `pensieve.language`. Needs
   `OPENAI_API_KEY` on the server; without it the recording stops here with that reason.
5. **Notes** (`pensieve.notes`, agent task): the bot Winky with the skill `meeting-notes`
   returns summary, decisions, actions (owner, due) and open questions as JSON; the
   server renders the Markdown in the owner's language. Skipped when `pensieve.notes` is
   off. Then routines with the `recording` trigger fire.

Files: `<data>/files/pensieve/<id>/audio.m4a`; transcript and notes in the `recordings`
table, so they can be searched.

## Sharing and privacy

A recording is its owner's. The owner shares it with the other person, who can read and
listen but not rename, share or delete it. Admins manage settings, never recordings.
Starting a recording is never an agent's; sharing through `burrowctl` asks the person.

## On the Mac

- **iCloud copy**: every finished recording the person can see is mirrored to
  `iCloud Drive/Pensieve/<date>_<title>/` (audio, transcript, notes) when
  `pensieve.mirror` is on. A marker file `.pensieve.json` follows renames; folders are
  never deleted.
- **RecHoarder import**: Archief › Importeer RecHoarder-opnames uploads
  `iCloud Drive/Meetings` once, with the transcripts and notes they had (source
  `imported`, so the server only compresses). Audio still only in iCloud is requested and
  imported on a later try.
- `PENSIEVE_SERVER` and `PENSIEVE_KEY` connect without the Keychain, for test runs.

## Choices

- Transcription in the cloud: Dobby's Celeron is far too slow for Whisper. A local
  engine fits the `Transcriber` interface if a faster machine arrives.
- The Mac uploads the WAV (lossless) and the server compresses, rather than compressing
  twice.
