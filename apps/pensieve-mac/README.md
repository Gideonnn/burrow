# Pensieve for macOS

Records calls (your microphone and whatever the Mac plays, so both sides), video
interviews, the screen and dictations; uploads only the audio to the Burrow server and
shows the transcript and the notes Kreacher writes. Video is compressed here and kept in
iCloud Drive. Recording needs macOS 14.2 or later, the screen macOS 15. See
`.agents/wiki/topics/pensieve.md`.

```bash
swift build && swift test            # from this folder
pnpm pensieve:install                # build, install in /Applications, start (from the repo root)
pnpm pensieve:release                # publish a signed build to every Mac
./scripts/make-icon.sh               # after changing Resources/AppIcon.svg
```

- ⌘N records, ⌘. stops; the menu bar item shows the meters and a stop button.
- Recordings wait in `~/Library/Application Support/Pensieve/Outbox` until the server
  has them; raw video waits in `…/Pensieve/Video` until its MP4 is safely in iCloud.
- Finished recordings are copied to `iCloud Drive/Pensieve` when that setting is on;
  video and screen recordings always.
- Archief › Importeer RecHoarder-opnames brings `iCloud Drive/Meetings` over once.
- Agents: `burrowctl pensieve state`, `show`, `search`, `open`, `label`, `transcribe`,
  `mark`, `share` (asks you), `stop`; never start a recording.
- The real-encoder test runs when ffmpeg is installed (it makes the sample video).

For a test server: `PENSIEVE_SERVER=http://127.0.0.1:4717 PENSIEVE_KEY=bk_… .build/debug/Pensieve`;
add `PENSIEVE_FOLDER=/tmp/pensieve-demo` to keep its copy out of iCloud Drive.
