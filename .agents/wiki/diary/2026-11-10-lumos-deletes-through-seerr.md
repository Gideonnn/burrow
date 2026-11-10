---
id: 2026-11-10-lumos-deletes-through-seerr
date: 2026-11-10
kind: decision
area: [lumos]
topics: [lumos]
---

# 2026-11-10 Lumos deletes through Seerr, only what Radarr or Sonarr manages

"Klaar in Jellyfin" became **Beheren**: what is under way with its progress, and the
library with a delete.

- **Through Seerr, no new keys.** Seerr's `DELETE /media/{id}/file` has Radarr or Sonarr
  remove the title with `deleteFiles=true`; `DELETE /media/{id}` then clears Seerr's
  record and requests, so the title can be asked for again. Rejected: a Radarr and Sonarr
  key on the server (per-season deletes would need Sonarr directly), and deleting in
  Jellyfin (Radarr would fetch a monitored film right back).
- **Trap: a hand-copied file.** On Dobby Jellyfin had 15 films and Radarr 8. For a title
  without `externalServiceId` Seerr logs "nothing to remove", marks it deleted and leaves
  the file, which the next availability sync shows again. Lumos refuses those with 409
  and the button says why.
- **`admin` only.** Mac keys of household admins carry it; bots never do, so no agent can
  delete. Lists stay; the outbox row turns `dropped` so a new "Ja" requests again.
- **Seerr's 204** has no body; `call` now parses only a non-empty answer.
