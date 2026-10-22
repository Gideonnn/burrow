---
id: 2026-10-22-deploys-restarted-the-tunnel
date: 2026-10-22
kind: trap
area: [infra, hedwig, pensieve]
topics: [deploy]
---

# 2026-10-22 Every deploy restarted the tunnel: 30 seconds of 530

Gideon saw Hedwig show "Er ging iets mis" with "Serverfout 530:" and Cloudflare's whole
error page (Cloudflare Tunnel error, code 1033) as HTML. The alert was taller than the
screen; after Enter the window had been pushed down until only its toolbar showed.

## Cause

`install.sh` ran `systemctl --user restart burrow-tunnel.service` on every run, so every
`pnpm server:deploy`. On SIGTERM cloudflared unregisters its connections and waits up to
its grace period (30 s by default) for open requests, and Hedwig's live stream is always
open. Meanwhile Cloudflare answers every request with 530/1033. All five tunnel restarts
that day matched a deploy. The server restart itself adds a second or two of 502 from
cloudflared ("origin unreachable").

The client then put any non-JSON body into the alert text, HTML included.

## Decisions

- The install restarts the tunnel only when its unit, the cloudflared binary or
  `tunnel.env` changed (a SHA-256 of the three in `~/.local/state/burrow/tunnel.stamp`,
  never the token itself), or when it is not running. `--grace-period 5s` shortens the
  rare restart that remains.
- The install waits for port 4718 too and prints how long the server took to answer.
- BurrowKit maps 502, 503, 504 and 520 to 530 without a JSON error, and connection errors,
  to `APIError.unavailable` ("Server even niet bereikbaar"). Our server always sends JSON
  with its own 502 and 503, so those keep their message. HTML never reaches an alert, and
  `ErrorText.short` caps any alert to four lines.
- Hedwig and Pensieve treat that error from a load, refresh, upload or the live stream
  quietly: the dot at the bottom of the sidebar turns orange, `ServerReachability` asks
  again after 2, 5, 10 and then every 30 seconds, and once the server answers they reload
  what they show. A user's own action (archive, approve) still says it briefly.
- `keepsWindowOnScreen()` moves a window back inside its screen when it appears, after a
  sheet or alert closes, and when the screens change.

## Rejected

- Restarting the tunnel with a zero grace period on every deploy: still a gap of a few
  seconds of 530 for nothing, since the tunnel's configuration lives at Cloudflare.
- Silently swallowing every error: a failed archive must not look like it worked.
