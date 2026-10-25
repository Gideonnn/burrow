---
id: 2026-10-25-lumos-live-from-seerr
date: 2026-10-25
kind: decision
area: [lumos, server, infra]
topics: [lumos, secrets]
---

# 2026-10-25 Lumos goes live on Seerr alone, and a list entry requests it

- **No TMDB key.** Seerr 3.5.1 already serves TMDB's discover, search, details, person
  credits, `relatedVideos` (trailer keys), artwork paths and `ratingscombined` (RT and
  IMDb), plus what the media server has. Rejected for now: a TMDB credential, needed only
  for release-type filters such as "Nieuw digitaal".
- **One Seerr service key** (Gideon's call): requests are the household's, not a
  person's. The key lives only in the media stack's root-only secrets, and the server
  runs as `dobby` without sudo, so the media stack's own admin route (in the operator's
  `tv` repository) copied it into Burrow's settings without showing it. Rejected: a
  Burrow script that asks for the sudo password, which also reran the whole install.
- **An outbox, not a call in the route.** The list row and its request row are written in
  one transaction, so a wish never lacks its request and Seerr being down never loses
  one. One row per title dedupes two people and two lists. Sending waits 15 seconds, so
  undo after J stops it; a sent request is never cancelled.
- **Series ask season 1** when no season is chosen: the research said never all seasons
  by default, and the Mac has no picker yet (`TODO.md`).
- Seerr's own answers carry user records with emails and tokens; the provider maps
  field by field, and a test pushes the key through every fake answer to prove none
  leaks.
