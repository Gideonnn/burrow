# Pensieve for macOS

Records a conversation (your microphone and whatever the Mac plays, so both sides of a
call), uploads it to the Burrow server, and shows the transcript and the notes Winky
writes. Recording needs macOS 14.2 or later. See `.agents/wiki/topics/pensieve.md`.

```bash
swift build && swift test            # from this folder
pnpm pensieve:install                # build, install in /Applications, start (from the repo root)
pnpm pensieve:release                # publish a signed build to every Mac
./scripts/make-icon.sh               # after changing Resources/AppIcon.svg
```

- ⌘N records, ⌘. stops; the menu bar item shows the meters and a stop button.
- Recordings wait in `~/Library/Application Support/Pensieve/Outbox` until the server
  has them.
- Finished recordings are copied to `iCloud Drive/Pensieve` when that setting is on.
- Archief › Importeer RecHoarder-opnames brings `iCloud Drive/Meetings` over once.
- Agents: `burrowctl pensieve state`, `search`, `open`, `share` (asks you), `stop`; never
  start a recording.

For a test server: `PENSIEVE_SERVER=http://127.0.0.1:4717 PENSIEVE_KEY=bk_… .build/debug/Pensieve`.
