---
id: 2026-10-27-jellyfin-12-wants-a-user-on-items-by-id
date: 2026-10-27
kind: trap
area: [lumos]
topics: [lumos]
---

# 2026-10-27 Jellyfin 12 wants a user on `/Items/{id}`

The first morning with the Jellyfin key on Dobby, every watch call answered 503 "Jellyfin
antwoordde 400". Jellyfin 12.3 returns `400 Error processing request.` for
`GET /Items/{id}` and `GET /Shows/NextUp` when the request carries a service API key and
no `userId`; `GET /Items?ids=` and `/Users/{userId}/Items/{id}` answer 200. The fake in
the tests accepted the id path, so the suite was green.

- **Fix:** the known id goes through `/Items?ids=…&fields=ProviderIds`; NextUp was already
  only asked with a screen's user. The fake now refuses the id path without a user.
- **Probe recipe:** a node script copied to Dobby that reads the env file itself and
  prints statuses and ids, never values; a throwaway key from `cli.sh create-key`, revoked
  in a trap, for calling the Burrow route on localhost. Routes live under `/api/`.
- Screens were empty with the TV off: Jellyfin keeps yesterday's sessions with
  `SupportsRemoteControl: false`, which the filter rightly drops.
