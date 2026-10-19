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
| Database, personal bots and skills, backups | `~/.local/share/burrow` |
| Log | `~/.local/state/burrow/server.log` (the user journal is not readable there) |
| Units | `~/.config/systemd/user/burrow.service`, `burrow-backup.{service,timer}`; linger is on, so they run without a login |
| Agent CLIs | `~/.local/bin/claude` and `/usr/bin/codex`, logged in as the `dobby` user |

The server listens on `127.0.0.1:4717` only. `tailscale serve` adds HTTPS on
`https://dobby-ubuntu.<tailnet>.ts.net`, the `BURROW_PUBLIC_URL` the first install
writes. Run the server CLI with the settings loaded through `infra/dobby/cli.sh`, e.g.
`~/burrow/infra/dobby/cli.sh list`.

## Remaining one-time steps

1. **Enable Serve for the tailnet.** The install prints a `login.tailscale.com/f/serve`
   link when Serve is off; open it once, then rerun the install. Until then Hedwig on the
   Mac reaches the server only through `ssh -L 4717:127.0.0.1:4717 dobby`.
2. **Google and Microsoft.** Put the client ids and secrets from the
   [providers topic](providers.md) in the settings file on Dobby and rerun the install.
   Their redirect URI is `<BURROW_PUBLIC_URL>/oauth/callback`.
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
