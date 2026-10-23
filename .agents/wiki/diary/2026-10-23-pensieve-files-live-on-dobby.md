---
id: 2026-10-23-pensieve-files-live-on-dobby
date: 2026-10-23
kind: decision
area: [pensieve, server, infra]
topics: [pensieve, deploy]
---

# 2026-10-23 Pensieve v6: iCloud is the source, Dobby keeps every file, links replace sharing

The v6 design (`docs/design/pensieve-v6.html`) builds on the current three-column app
after four alternative homes (tiles, a week agenda, ask-first, piles per label) looked
good but used a lot of space without being more useful. Not built yet; see `TODO.md`.

## Decisions

- **Dobby keeps a copy of every file, video included.** This reverses "video stays on
  the Mac and in iCloud" from 2026-10-22. Dobby has 1 TB (video is about 400 to 830 MB
  an hour), the copy doubles as a backup, and share links can be served at once. The
  operator wants this for all of Burrow, with an off-site backup from Dobby later (B2 or
  similar). `infra/dobby/backup.sh` still covers only the database.
- **`iCloud Drive/Pensieve` is the source of truth.** The app follows the folder: an added
  file or folder becomes a recording (a loose file gets its own folder with the audio
  next to it, the file itself untouched), renames and Finder tags come back, edited
  `transcript.md` and `samenvatting.md` are taken over. Something deleted turns grey in
  the app with "Zet terug", restored from Dobby's copy, kept 30 days by default.
- **No sharing between household members.** Gideon and Eva never share recordings, so
  "Van mij", "Gedeeld met mij" and the avatars go. The generic `packages/platform` shares
  stay; Pensieve's share routes can go when the UI is built.
- **Stuur: the macOS share sheet plus a link served by Dobby.** Default one download,
  always 24 hours, 3 or 10 downloads on request; a download counts once it completes;
  links can be revoked. The receive page needs only a browser: no account, app, cookies
  or trackers, and `noindex`. Rejected: a magic-wormhole style code with WebRTC (the
  receiver must be online at the same moment, school networks block peer-to-peer so a
  relay is needed anyway, and WebRTC on the Mac is heavy); a key in the link fragment
  with browser decryption (pointless once Dobby holds the file); LocalSend (receiver
  needs an app).
