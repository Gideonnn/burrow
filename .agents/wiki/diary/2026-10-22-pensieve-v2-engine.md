---
id: 2026-10-22-pensieve-v2-engine
date: 2026-10-22
kind: decision
area: [pensieve, server]
topics: [pensieve, mcp, agent-control]
---

# 2026-10-22 Pensieve v2: four kinds, video on the Mac, labels per person

The v3 design (`docs/design/pensieve.html`) turned Pensieve from one kind of recording
into four, with marks, labels, subtitles and a shrink tool. The engine was built before
the UI: server, contracts, Mac core, capture and agent control; the screens wait.

## Decisions

- **Only the diarizing model gives timestamps.** OpenAI's docs (checked 2026-10-22):
  `timestamp_granularities` is whisper-1 only, `gpt-4o-transcribe` and the new
  `gpt-transcribe` return text, `gpt-4o-transcribe-diarize` returns segments with start,
  end and speaker (`diarized_json`, and `chunking_strategy` is required past 30 s). So
  video, screen and speaker requests go to the diarizing model, with speakers dropped
  when the person did not ask for them. Rejected: whisper-1 for timestamps (older, worse
  on Dutch, also deprecated). Both 4o models shut down on 2027-02-26: a successor with
  timestamps is open.
- **Part offsets are measured, not multiplied.** `ffmpeg -f segment -c copy` cuts on
  packet boundaries, so `Audio.split` returns each part's start from ffprobe. The test
  that asked for starts failed before the change.
- **Labels belong to a person, not to a recording.** Someone a recording was shared with
  can file it under their own label without the owner seeing; filters match by name so
  own and shared recordings mix. Rejected: owner's labels visible to all (labels are
  private filing, and Finder tags on each Mac follow the person).
- **Marks as JSON on the recording**, not a table: they arrive with the upload, are
  replaced as a whole, and search finds their notes with the same `LIKE`.
- **Notes tagged by `type`** in the existing column; old rows read as meeting notes. In
  Swift one struct carries every list, so the current views still compile.
- **Video never reaches the server.** Dobby's Celeron cannot encode it and raw video is
  gigabytes. The Mac extracts the sound for transcription and keeps the original on a
  shelf until the MP4 is in the iCloud folder, plays, and iCloud says it is uploaded.
  The iCloud folder is the video's only home, so it is written even with the copy
  switched off.
- **Paste by clipboard and Command-V**, restoring the clipboard unless someone copied
  meanwhile. Rejected: setting `kAXSelectedText` on the focused element, which browsers
  and Electron apps accept and then ignore.
- **Carbon hot key for hold-to-talk.** It reports press and release and needs no
  Accessibility; an `NSEvent` global monitor would, and cannot swallow the space.
- **Shrink with a limit aims at 95 %** and checks the file: the encoder's average bitrate
  overshoots on busy video, so an overshoot is encoded again at a bitrate scaled by how
  far it missed, dropping height when the bitrate falls under what the height needs.

## Traps

- `drizzle-kit generate` produced `DEFAULT true` for a boolean column; SQLite accepts it.
- A unique index on `lower(name)` only folds ASCII; label matching is done in code with
  `toLocaleLowerCase`, the index only stops exact doubles.
- The repository's secret hook blocks Bash commands containing `.key` after a subscript
  (it read `registered[id]?.key` as a secret); name such properties differently.
- Two calls to compress videos raced: the one started at launch could encode a new item
  before the upload bound it to its recording, so nothing mirrored it. Compression now
  runs as one task that later callers wait on and that loops while asked again.
- `#expect` with a chained `map` and float rounding made the Swift type checker give up;
  split such expressions.
