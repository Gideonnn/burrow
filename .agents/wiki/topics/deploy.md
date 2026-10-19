# Deploy to Dobby

The server runs on Dobby, a small Linux machine at home, in Docker Compose
(`infra/dobby/compose.yml`). It listens only on Dobby's loopback; `tailscale serve`
publishes it to the tailnet with HTTPS, so nothing is open to the home network or the
internet. Deploys run from the Mac with `./infra/dobby/deploy.sh`, which updates the
checkout on Dobby to `origin/main`, streams the decrypted environment over SSH, rebuilds
and checks `/health`.

## What lives where

| Thing | Where |
|---|---|
| Database, personal bots and skills | Docker volume `burrow_data` (`/data`) |
| Claude Code and Codex logins | Volumes `burrow_claude` and `burrow_codex` |
| Environment (secrets) | `infra/dobby/burrow.env.enc` in git (SOPS, age), plaintext only on Dobby as `burrow.env` (mode 600) |
| Backups | `infra/dobby/backups/*.sqlite.age` on Dobby, nightly, last 30 kept |

## First setup

Each step is done once. The operator runs them; they change Dobby or create secrets.

1. **SSH.** Make `ssh dobby` work from the Mac (a `Host dobby` entry pointing at the
   tailnet name), and accept its host key once.
2. **Docker and Tailscale on Dobby.** Install Docker Engine with the Compose plugin, and
   add the user to the `docker` group. Tailscale is already running.
3. **Secrets.** On the Mac: create an age key if needed (`age-keygen`), copy
   `.sops.yaml.example` to `.sops.yaml` with its public key, then create the env file
   from `infra/dobby/burrow.env.example` and encrypt it:
   `sops --encrypt --input-type dotenv --output-type dotenv burrow.env > infra/dobby/burrow.env.enc`.
   Delete the plaintext afterwards. The Google and Microsoft values come from the
   [providers topic](providers.md); their redirect URI is `<BURROW_PUBLIC_URL>/oauth/callback`.
4. **Deploy.** `./infra/dobby/deploy.sh`.
5. **HTTPS on the tailnet.** On Dobby: `sudo tailscale serve --bg --https=443 http://127.0.0.1:4717`.
   The name it prints is `BURROW_PUBLIC_URL`; if it differs from step 3, update the
   secret and deploy again.
6. **Agent logins.** On Dobby, log the agent CLIs in once inside the container:
   `docker compose exec -it server claude` (finish the login, then `/exit`), and the same
   with `codex login` if Codex should be the fallback.
7. **First person and admin key.** `docker compose exec server node dist/cli.js init Gideon`
   prints the admin key once; put it in Hedwig. Add other people with `add-person` and
   give them keys through the API or Hedwig's settings.
8. **Backups.** Put the age public keys for backups in `infra/dobby/backup-recipients.txt`
   on Dobby (one per line; at least one whose private key is not on Dobby), install
   `age`, then copy `burrow-backup.service` and `.timer` to `~/.config/systemd/user/`
   and run `systemctl --user enable --now burrow-backup.timer` (with
   `loginctl enable-linger` so it runs without a session).

## Restoring

Stop the server, decrypt a backup with `age --decrypt -i <key> backups/<file>.age >
burrow.sqlite`, copy it into the `burrow_data` volume as `/data/burrow.sqlite`, start the
server. The same `BURROW_SECRET_KEY` is needed, or every mailbox has to be reconnected.
