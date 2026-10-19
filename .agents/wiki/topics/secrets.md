# Secrets

Few secrets exist, and none of them belong in git as plaintext. Per-user OAuth tokens
and API key hashes live in the server's database on Dobby, never in the repository. What remains is
deployment configuration (OAuth client credentials, a backup encryption key, the Cloudflare
Tunnel token).

## Where the server's secrets live

The first install on Dobby generates `BURROW_SECRET_KEY` there and keeps every server
secret in the settings file under `~/.config/burrow/` (mode 600), next to the OAuth client
credentials the operator adds. The Cloudflare Tunnel token has its own file there, so the server and the agents it runs never see it. Nothing is in git. SOPS below is only needed if secrets
ever move into the repository.

## SOPS in a public repository

SOPS with age is designed for this: values are encrypted with AES-256-GCM to the listed
age public keys, so publishing the ciphertext is safe. The rules that keep it safe:

- **Key names and file structure stay readable.** Never put a secret in a key name or a
  comment.
- **History is forever.** If an age private key leaks, every encrypted file in the
  history is readable. Rotate the secrets themselves, not only the encryption.
- **Recipients**: only Gideon's Mac and Dobby. Private keys never leave those machines.
- **Plaintext must not slip in.** The `block-secrets` hook stops agents from reading or
  writing env files; a secret scanner (gitleaks) runs before commits and in CI.
- **Forks and pull requests from others cannot decrypt.** CI jobs that need secrets only
  run on branches in this repository.
