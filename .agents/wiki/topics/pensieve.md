# Pensieve

Pensieve keeps four kinds of recording made on the Mac: a **call** (your microphone plus
whatever the Mac plays, so both sides of a Zoom or Teams call), a **video** (webcam plus
microphone, for interviews), a **screen** recording (screen plus Mac audio, the
microphone when asked) and a **dictation** (hold Option+Space anywhere, talk, the text is
pasted at the cursor). The server gets only audio: it compresses, transcribes and writes
notes. Video stays on the Mac and in iCloud. It replaced RecHoarder (`~/git/rechoarder`),
whose capture code lives on in `apps/pensieve-mac/Sources/PensieveCapture`. Plan:
`docs/plans/2026-10-22-pensieve-v2.md`; design: `docs/design/pensieve-v6.html`, which also
moves video to Dobby, follows the iCloud folder and replaces sharing with links (not built
yet, see the [diary](../diary/2026-10-23-pensieve-files-live-on-dobby.md)).

## The pipeline

1. **Record** in Pensieve.app. A call is a private aggregate device of the chosen
   microphone and a Core Audio process tap (macOS 14.2+), mixed to a 16 kHz mono WAV in
   `~/Library/Application Support/Pensieve/Outbox`. Video (AVCaptureSession) and screen
   (ScreenCaptureKit's recording output, macOS 15) go to a raw `.mov` on the **shelf**,
   `…/Pensieve/Video`; their sound is extracted to an m4a in the outbox. Dictation is AAC
   straight into the outbox. Marks ("Markeer moment") are seconds from the start with an
   optional note. Nothing leaves the Mac until Stop.
2. **Upload** the audio in 16 MB chunks (`POST /api/uploads`, `PUT …?offset=`) with kind,
   marks and labels; an interrupted upload resumes, a recording waits in the outbox until
   the server has it.
3. **Compress** (task `pensieve.compress`, server): ffmpeg to AAC, mono, 16 kHz,
   32 kbit/s, about 14 MB an hour; the upload is deleted.
4. **Transcribe** (`pensieve.transcribe`) automatically for calls and dictations; video
   and screen stay `stored` until the owner asks (`POST …/transcribe`, "Maak transcript").
   Split into 20-minute parts (OpenAI caps 1400 s and 25 MB); each part carries its
   measured start, so segment times stay on the whole recording. Video, screen and any
   recording with `pensieve.speakers` on go to `gpt-4o-transcribe-diarize`
   (`diarized_json`, `chunking_strategy: auto`), the only current model with timestamps;
   the rest to `gpt-4o-transcribe` as text. Segments (start, end, speaker, text) are
   stored beside the plain transcript that search uses; `GET …/subtitles` makes SRT from
   them. Needs `OPENAI_API_KEY` on the server.
5. **Notes** (`pensieve.notes`, agent task, Kreacher on Opus) per kind: calls get
   `meeting-notes` (summary, decisions, actions, open questions), video `interview-notes`
   (core, quotes with their moment, chapters), screen `screen-steps` (summary, steps).
   The prompt has the transcript with `[mm:ss]` per segment and the marks, both fenced as
   untrusted. Dictation has none: it is done after the transcript and a dictation called
   "Dictaat" is named after its first words. Skipped when `pensieve.notes` is off. Then
   routines with the `recording` trigger fire.

Dictations run at priority `urgent` (someone waits to paste). Notes are stored as JSON
tagged by `type` (`meeting`, `interview`, `steps`); rows from before the tag are meeting
notes. Files: `<data>/files/pensieve/<id>/audio.m4a`; everything else in `recordings`.

## Labels

Free text, no colours, each person's own: a person labels any recording they can see
(their own or shared with them), sees only their own labels, and filters on them by name
(several labels are OR). The list filters by kind too; search matches titles,
transcripts, notes, mark notes and label names. `GET|POST /api/pensieve/labels`,
`PATCH|DELETE /api/pensieve/labels/:id` (renaming onto an existing name merges),
`PUT /api/pensieve/recordings/:id/labels`.

## Sharing and privacy

A recording is its owner's. The owner shares it with the other person, who can read and
listen and put their own labels on it, but not rename, mark, transcribe, share or delete
it. Admins manage settings, never recordings. Starting a recording is never an agent's;
`burrowctl pensieve` can stop, mark, label and transcribe, and sharing asks the person.

## On the Mac

- **Video sizes** (`PensieveMedia`): H.264 MP4 on the hardware encoder through
  AVAssetWriter. 1080p 13.8, 720p 6.9, 480p 3.4 MB a minute; a recording keeps small
  720p, normal 1080p (default) or high. Never upscaled; a portrait video keeps its
  rotation.
- **The shelf**: the raw original waits until its MP4 is made, copied into the
  recording's iCloud folder, plays there (size and a video track) and iCloud reports it
  uploaded. Only then are the original and the shelf's copy deleted.
- **iCloud copy**: `iCloud Drive/Pensieve/yyyy-MM-dd_<slug>/` (lowercase, accents folded)
  with `<slug>.mp4`, `audio.m4a` (always, so a better model can transcribe again without
  the video), `samenvatting.md` (with the marks), `transcript.md` (`**mm:ss** A: …`),
  `ondertitels.srt` and `.pensieve.json`; labels are Finder tags. Dictations share
  `dictaten/`, as `<date>_<time>_<slug>.md` and `.m4a`, with one index file. The marker
  follows renames and holds `layout: 2`; a folder of the first copy has `notulen.md` and
  `transcript.txt` renamed in place. With `pensieve.mirror` off, video and screen still
  go there: it is their only home. Folders are never deleted.
- **Verklein video** (`VideoShrink`): any video, three qualities with estimated sizes, an
  optional limit; with a limit the encode aims at 95 %, is checked, and is redone lower
  when it overshoots. A file already small enough is left alone. Output next to the
  original as `<slug>-<height>p.mp4`.
- **Dictation**: a Carbon hot key (press and release; no Accessibility needed), the
  upload, a wait for the transcript, then the paster puts the text on the clipboard and
  sends Command-V and restores the clipboard; without Accessibility it stays on the
  clipboard. On by default (Settings › Algemeen › Dictaten); when another app holds
  ⌥ Spatie, Settings says so. A pill at the bottom of the screen shows listening,
  transcribing and where the text went.
- **The window** follows Hedwig: kinds in the sidebar with counts, Hedwig's server card,
  the red button that records the kind of last time (⌘1-3 pick one), Stuur (the share
  sheet on the file in iCloud), Verklein and Toon in Finder as one toolbar group, and
  search as the toolbar field. The detail is one column: `AVPlayerView` (SwiftUI's
  `VideoPlayer` does not load in a package executable), the timeline of speakers and
  marks, the transcript following playback, the summary per kind, the folder's files.
  While a call or the screen is recorded with Pensieve in the background, a bubble
  floats above every app. Settings on this Mac live in `MacSettings`.
- **RecHoarder import**: Archief › Importeer RecHoarder-opnames uploads
  `iCloud Drive/Meetings` once, with the transcripts and notes they had (source
  `imported`, so the server only compresses).
- `PENSIEVE_SERVER` and `PENSIEVE_KEY` connect without the Keychain, for test runs;
  `PENSIEVE_FOLDER` moves the iCloud copy elsewhere so a demo leaves iCloud alone.

## Choices

- Transcription in the cloud: Dobby's Celeron is far too slow for Whisper, and far too
  slow to compress video, which is why the Mac does that.
- A call uploads the WAV (lossless) and the server compresses, rather than compressing
  twice. Video uploads only extracted audio; raw video to the server would be pointless.
- The speaker letters restart per 20-minute part, and the diarizing model shuts down on
  2027-02-26; see the plan's open questions.
