---
id: 2026-10-19-tailscale-dropped-for-cloudflare
date: 2026-10-19
kind: decision
area: [server, infra]
topics: [deploy, providers]
---

# Tailscale dropped for Cloudflare

Hours after [adding Cloudflare Access next to Tailscale](2026-10-19-public-access-through-cloudflare-access.md),
Gideon chose one route for everything: the Cloudflare Tunnel. The install no longer runs
`tailscale serve`, and Hedwig, agents and MCP use the public hostname.

Decisions and rejected alternatives:

- **`/api/*` bypasses Access; the API key is the lock.** Keys carry 256 random bits, so
  guessing is hopeless, and a Cloudflare rate limit on `/api/` keeps strangers from
  hammering it. Rejected: a Cloudflare service token per client, which adds a second
  secret to Hedwig and every MCP config for little gain, since it would live next to the
  API key anyway. It also keeps the door open for MCP connectors that run in the cloud.
- **Browser pages keep the Access login and the server's own check** of its token and
  the person behind it, as before.
- **SSH goes through the same tunnel** (`cloudflared access ssh` as the SSH proxy on the
  Mac), so deploying works from anywhere without Tailscale.
- **Port 4717 stays, local only**, for the install's health check and debugging over
  SSH. Folding everything onto the tunnel port would put the health check behind Access.

Correction the same day: SSH stays on the operator's existing private route, because it
serves other work too. Only Burrow's web traffic moved to Cloudflare.
