# Deploy to Dobby

The server runs on Dobby (Ubuntu, x86_64) as a systemd **user** service, without Docker
or sudo: `infra/dobby/install.sh` builds the checkout in `~/burrow`, writes the settings
once, installs `burrow.service` and a nightly backup timer, waits for `/health` and
publishes the port on the tailnet with `tailscale serve`. From the Mac,
`pnpm server:deploy` (`infra/dobby/deploy.sh`) moves Dobby's checkout to `origin/main` and
runs the install again. Every step is safe to repeat.

## What lives where on Dobby

| Thing | Where |
|---|---|
| Code | `~/burrow` (detached at the deployed commit) |
| Settings and secrets | `~/.config/burrow/burrow.env`, mode 600, created by the first install; never printed, copied or committed |
| Tunnel token | `~/.config/burrow/tunnel.env`, mode 600, written by the operator |
| Database, personal bots and skills, backups | `~/.local/share/burrow` |
| Log | `~/.local/state/burrow/server.log` (the user journal is not readable there) |
| Units | `~/.config/systemd/user/burrow.service`, `burrow-backup.{service,timer}`, `burrow-tunnel.service` when a tunnel token exists; linger is on, so they run without a login |
| Agent CLIs | `~/.local/bin/claude` and `/usr/bin/codex`, logged in as the `dobby` user |

The server listens on `127.0.0.1:4717` only. `tailscale serve` adds HTTPS on
`https://dobby-ubuntu.<tailnet>.ts.net`, the `BURROW_PUBLIC_URL` the first install
writes. Run the server CLI with the settings loaded through `infra/dobby/cli.sh`, e.g.
`~/burrow/infra/dobby/cli.sh list`.

## Public access: Cloudflare Tunnel and Access

Household members without Tailscale reach the server on a public hostname through a
Cloudflare Tunnel, with Cloudflare Access asking for a login first. The tunnel points at a
**second port, 4718**, which the server opens only when `CLOUDFLARE_ACCESS_TEAM` and
`CLOUDFLARE_ACCESS_AUD` are set. On that port every request needs a valid Access token
(`Cf-Access-Jwt-Assertion`, checked against the team's keys and the application's
audience tag) whose email belongs to a person; API routes still need a key on top. Port
4717 stays for the tailnet, so Hedwig and agents keep using Serve and their keys.
Code: `apps/server/src/auth/cloudflareAccess.ts`.

Setup, in this order so the hostname is never open without a login:

1. **Access application** (Zero Trust › Access › Applications, self-hosted) for the
   public hostname, with an Allow policy listing the household's addresses. Copy the
   *Application Audience (AUD) tag*.
2. **Settings on Dobby:** in the server settings file set `CLOUDFLARE_ACCESS_TEAM` (the
   team domain, `<team>.cloudflareaccess.com`), `CLOUDFLARE_ACCESS_AUD` and
   `BURROW_PUBLIC_URL=https://<public hostname>`. Give each person their login address:
   `~/burrow/infra/dobby/cli.sh set-email <name> <email>`.
3. **Tunnel** (Zero Trust › Networks › Tunnels): create one, add the public hostname with
   service `http://127.0.0.1:4718`, and put its token as `TUNNEL_TOKEN=` in
   `~/.config/burrow/tunnel.env` (mode 600). That file is separate so the server and
   its agents never see the token.
4. **Rerun the install.** It downloads `cloudflared` into `~/.local/bin` and runs it as
   `burrow-tunnel.service`; its log is `~/.local/state/burrow/tunnel.log`.
5. **OAuth redirect URIs** at Google and Microsoft become
   `https://<public hostname>/oauth/callback`.

Cloudflare terminates TLS, so it can read the traffic that passes through the tunnel,
mail included. The tailnet does not have that property.

## Remaining one-time steps

1. **Enable Serve for the tailnet.** The install prints a `login.tailscale.com/f/serve`
   link when Serve is off; open it once, then rerun the install. Until then Hedwig on the
   Mac reaches the server only through `ssh -L 4717:127.0.0.1:4717 dobby`.
2. **Google and Microsoft.** Put the client ids and secrets from the
   [providers topic](providers.md) in the settings file on Dobby and rerun the install.
   Their redirect URI is `<BURROW_PUBLIC_URL>/oauth/callback`; with the tunnel that is
   the public hostname.
3. **Backups off the machine.** Put age public keys in `infra/dobby/backup-recipients.txt`
   on Dobby (at least one whose private key is elsewhere); without it backups are plain
   copies in the data folder. Copy them off Dobby regularly.

## Traps

- `tailscale serve` without Serve enabled prints a link and **waits**; the install wraps
  it in a timeout.
- Rebuilding used to nest `dist/migrations/migrations`, and the restarted server could
  not find its migrations. The build now replaces the folder, and CI builds twice.

## Docker

`apps/server/Dockerfile` still builds a self-contained image (CI builds and starts it),
for hosts where Docker is the easier route. Dobby does not use it.

## Restoring

Stop the service, copy a backup over `~/.local/share/burrow/burrow.sqlite` (decrypt it
first with `age --decrypt` when encrypted), start the service. The same
`BURROW_SECRET_KEY` is needed, or every mailbox has to be reconnected.
