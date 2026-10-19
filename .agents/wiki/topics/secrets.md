# Secrets

Few secrets exist, and none of them belong in git as plaintext. Per-user OAuth tokens
and API key hashes live in the server's database on Dobby. Server settings stay on Dobby.
Tokens for the operator's own tooling, such as the Cloudflare API token, live in git
encrypted with SOPS, as in the Colloport repository.

## Where the server's secrets live

The first install on Dobby generates `BURROW_SECRET_KEY` there and keeps every server
secret in the settings file under `~/.config/burrow/` (mode 600), next to the OAuth client
credentials the operator adds. The Cloudflare Tunnel token has its own file there, so the
server and the agents it runs never see it. None of this is in git.

## Operator tooling: SOPS

SOPS encrypts a dotenv file to a list of age public keys, its **recipients**; only a
holder of one of the private keys can decrypt it. `.sops.yaml` maps each file to its
recipients.

| File | Holds | Recipients |
|---|---|---|
| `infra/secrets/tools.env.enc` | `CLOUDFLARE_API_TOKEN`: DNS, WAF and settings of the household's zone, plus Tunnel and Access on the account | the operator's Mac |

- **Agents never run `sops`.** They use the values through
  `pnpm with-secrets <file> <command>`, which puts them in the command's environment, and
  check a file with `pnpm sops:verify <file>`, which prints key names and lengths only.
  The `pre-tool` hook blocks every other `sops` call.
- **The operator edits** with `pnpm sops:edit infra/secrets/<file>.env.enc`, which opens
  the decrypted file in the editor and encrypts it again on save.
- **One file per recipient set.** Before adding a key to a file, ask whether every
  recipient needs it. A secret Dobby needs goes in a new file with Dobby's key, not in
  `tools`.

## SOPS in a public repository

Values are encrypted with AES-256-GCM, so publishing the ciphertext is safe. The rules
that keep it safe:

- **Key names and file structure stay readable.** Never put a secret in a key name or a
  comment.
- **History is forever.** If an age private key leaks, every encrypted file in the
  history is readable. Rotate the secrets themselves, not only the encryption.
- **Private keys never leave their machine.** The operator's key is shared with other
  projects; rotating it is a cross-project job.
- **Plaintext must not slip in.** The `block-secrets` hook stops agents from reading or
  writing env files; gitleaks scans every push in CI.
