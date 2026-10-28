# Deploy to Dobby

The server runs on Dobby (Ubuntu, x86_64) as a systemd **user** service, without Docker
or sudo: `infra/dobby/install.sh` builds the checkout in `~/burrow`, writes the settings
once, installs `burrow.service`, a nightly backup timer and, once a token exists, the
Cloudflare Tunnel, then waits for `/health` (and for port 4718 when Access is set). From
the Mac, `pnpm server:deploy` (`infra/dobby/deploy.sh`) moves Dobby's checkout to
`origin/main` over SSH and runs the install again. Every step is safe to repeat.

## What lives where on Dobby

| Thing | Where |
|---|---|
| Code | `~/burrow` (detached at the deployed commit) |
| Settings and secrets | `~/.config/burrow/burrow.env`, mode 600, created by the first install; never printed, copied or committed |
| Tunnel token | `~/.config/burrow/tunnel.env`, mode 600, written by the operator |
| Database, personal bots and skills, backups | `~/.local/share/burrow` |
| Logs | `~/.local/state/burrow/server.log` and `tunnel.log` (the user journal is not readable there) |
| Units | `~/.config/systemd/user/burrow.service`, `burrow-backup.{service,timer}`, `burrow-tunnel.service` when a tunnel token exists; linger is on, so they run without a login |
| Agent CLIs | `~/.local/bin/claude` and `/usr/bin/codex`, logged in as the `dobby` user |
| ffmpeg, ffprobe | `~/.local/bin`, a static build installed by `install.sh` (checked against its SHA-256) |
| Recordings | `~/.local/share/burrow/files/pensieve/<id>/audio.m4a` |

Run the server CLI with the settings loaded through `infra/dobby/cli.sh`, e.g.
`~/burrow/infra/dobby/cli.sh list`. A lost key cannot be recovered (only its hash is stored): make a new one with `cli.sh create-key <person> <key name> [rights]` and revoke the old one in Hedwig, or on Dobby with `cli.sh revoke-key <key id>` (ids from `list`).

## How it is reached: Cloudflare Tunnel and Access

Everything outside Dobby reaches the server on one public hostname through a Cloudflare
Tunnel; no port on the home router is open. The server listens on two local ports:

- **4717**, unauthenticated apart from API keys, for Dobby itself (the install's health
  check, `ssh -L 4717:127.0.0.1:4717 dobby` when debugging).
- **4718**, which the tunnel points at, opened only when `CLOUDFLARE_ACCESS_TEAM` and
  `CLOUDFLARE_ACCESS_AUD` are set. Browser pages there need a valid Access token
  (`Cf-Access-Jwt-Assertion`, checked against the team's keys and the application's
  audience tag) whose email belongs to a person. `/api/*` passes without it: Access lets
  it through so Hedwig, agents and MCP need only their API key, which every API route
  checks. Code: `apps/server/src/auth/cloudflareAccess.ts`.

Setup, in this order so the hostname is never open without a login:

1. **Access applications** (Zero Trust › Access › Applications, self-hosted):
   - the public hostname, with an Allow policy listing the household's addresses. Copy
     its *Application Audience (AUD) tag*;
   - the same hostname with path `api`, with a **Bypass** policy for Everyone. The more
     specific path wins.
2. **Rate limit** (the zone › Security › WAF › Rate limiting rules): one rule on
   `/api/` per IP, so a stranger cannot hammer the API.
3. **Settings on Dobby:** in the server settings file set `CLOUDFLARE_ACCESS_TEAM` (the
   team domain, `<team>.cloudflareaccess.com`), `CLOUDFLARE_ACCESS_AUD` and
   `BURROW_PUBLIC_URL=https://<public hostname>`. Give each person their login address:
   `~/burrow/infra/dobby/cli.sh set-email <name> <email>`.
4. **Tunnel** (Zero Trust › Networks › Tunnels): create one, add the public hostname with
   service `http://127.0.0.1:4718`, and put its token as `TUNNEL_TOKEN=` in
   `~/.config/burrow/tunnel.env` (mode 600). That file is separate so the server and
   its agents never see the token.
5. **Rerun the install.** It downloads `cloudflared` into `~/.local/bin` and runs it as
   `burrow-tunnel.service`. Later installs restart it only when its unit, `cloudflared` or
   `tunnel.env` changed (a hash in `~/.local/state/burrow/tunnel.stamp`) or when it is not
   running; an unchanged tunnel is left alone.
6. **Clients:** Hedwig's server address and MCP URLs become `https://<public hostname>`.

Cloudflare terminates TLS, so it can read the traffic that passes through the tunnel,
mail included. Accepted for the household.

## SSH

Deploying and the CLI use `ssh dobby`, over whatever private route the operator already
has to the machine. The tunnel carries only Burrow's web traffic, not SSH.

## Public pages

`/about`, `/privacy` and `/terms` open without a login, for Google's OAuth branding. They
need their own Access application, "Burrow public pages", with a Bypass policy for
Everyone on exactly those three paths; the server lets only those exact paths through as
well. `BURROW_CONTACT_EMAIL` in the settings fills in the contact on them.

## Remaining one-time steps

1. **Google and Microsoft.** Put the client ids and secrets from the
   [providers topic](providers.md) in the settings file on Dobby and rerun the install.
   Their redirect URI is `<BURROW_PUBLIC_URL>/oauth/callback`.
2. **Transcription.** Run `pnpm dobby:set OPENAI_API_KEY` on the Mac: it asks for the key
   hidden, writes it to the settings file on Dobby and restarts the
   service. Without it Pensieve stops recordings at "Transcriberen". The same command sets
   any other single value in the settings.
3. **Backups off the machine.** Put age public keys in `infra/dobby/backup-recipients.txt`
   on Dobby (at least one whose private key is elsewhere); without it backups are plain
   copies in the data folder. Copy them off Dobby regularly.

## Traps

- Restarting the tunnel makes Cloudflare answer 530 (error 1033) until cloudflared has
  reconnected: up to its grace period, which open requests such as Hedwig's live stream
  always fill. Deploys used to restart it every time; now only a changed tunnel restarts,
  with `--grace-period 5s`. A server restart still gives a second or two of 502; the Mac
  apps retry both quietly and show it in the sidebar's connection dot. See the
  [diary](../diary/2026-10-22-deploys-restarted-the-tunnel.md).
- Rebuilding used to nest `dist/migrations/migrations`, and the restarted server could
  not find its migrations. The build now replaces the folder, and CI builds twice.
- An Access login is not enough for `/api`: the server still wants a key, so a browser
  cannot call the API yet. A web interface needs its own session on top of the login.

## Docker

`apps/server/Dockerfile` still builds a self-contained image (CI builds and starts it),
for hosts where Docker is the easier route. Dobby does not use it.

## Restoring

Stop the service, copy a backup over `~/.local/share/burrow/burrow.sqlite` (decrypt it
first with `age --decrypt` when encrypted), start the service. The same
`BURROW_SECRET_KEY` is needed, or every mailbox has to be reconnected.
