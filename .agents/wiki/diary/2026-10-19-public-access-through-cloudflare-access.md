---
id: 2026-10-19-public-access-through-cloudflare-access
date: 2026-10-19
kind: decision
area: [server, infra]
topics: [deploy, secrets]
---

# Public access through Cloudflare Access

Tailscale alone works for Gideon but not for a household member who should not have to
install it, and a web interface for settings is planned. Decided: a Cloudflare Tunnel
on a public hostname with Cloudflare Access in front, and the server checks the Access
token itself as a second line of defence.

Decisions and rejected alternatives:

- **Cloudflare Access over Tailscale Funnel.** Funnel needs one command but publishes the
  server with nothing in front except API keys, and the server has no rate limiting.
  Access puts a login (one-time code or Google) before any request reaches Dobby.
- **A second port (4718) for the tunnel** instead of recognising tunnel traffic by its
  `Host` or `Cf-*` headers. Tailscale Serve and the tunnel both forward to localhost, so
  only the port tells them apart reliably. Both ports serve the same app, which matters:
  an OAuth link requested over the tailnet is completed in a browser on the public
  hostname, and the pending handles live in that one app.
- **Email mapped to a person** (`people.email`, set with `cli set-email`). A valid
  Access login that is no person of the household is refused, so a too-wide Access policy
  does not open the server.
- **Hedwig and agents stay on the tailnet.** Access would block their bearer keys unless
  each got a Cloudflare service token; not worth it while Tailscale works for them.
- **Tunnel token in its own file** next to the server settings, read only by the
  `cloudflared` unit. The server runs agent CLIs on untrusted mail and they inherit its
  environment.
- **Accepted trade-off:** Cloudflare terminates TLS and can read the traffic. The tailnet
  remains the end-to-end encrypted route.
