---
id: 2026-10-19-operator-tokens-in-sops
date: 2026-10-19
kind: decision
area: [repo, infra]
topics: [secrets]
---

# Operator tokens in SOPS

A Cloudflare API token lets agents change DNS, rate limits and Access instead of the
operator clicking through the dashboard. Decided: keep it in `infra/secrets/tools.env.enc`,
encrypted with SOPS to the operator's age key, the same pattern as the Colloport
repository. Agents use it through `pnpm with-secrets`; the `pre-tool` hook blocks any
other `sops` call.

Rejected:

- **macOS Keychain.** Works for one Mac, but the token would not travel with the repo and
  every tool would need its own lookup.
- **Bitwarden CLI.** Needs an unlocked vault per shell; an agent cannot unlock it, and
  storing the session key in a profile is weaker than either alternative.

`.sops.yaml` used to be gitignored while it held nothing; it is committed now, since
every encrypted file carries its recipients' public keys anyway.
