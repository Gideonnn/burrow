# TODO

Issue-ready entries, roughly in build order. Delete an entry in the commit that finishes it.

## First deploy on Dobby (operator)

**What:** the one-time steps in the deploy topic: SSH alias and host key, Docker on
Dobby, the SOPS-encrypted environment, `tailscale serve`, the agent logins in the
container, `cli init`, and the backup timer with its age recipients.
**Why:** the artifacts exist and CI builds and starts the image, but only Gideon can
create the secrets and change Dobby.
**Scope:** about an hour, following `.agents/wiki/topics/deploy.md`.

## Routines, task queue and runners on clients

**What:** Portkey routines as data (trigger plus task type plus skill), the task queue, and
runners in client apps. Invoice processing is the first routine. **Why:** household
automation beyond mail. **Scope:** design note first.

## Open-source readiness

**What:** choose a licence, add GitHub Actions (format check, lint, typecheck, tests, hook
tests) and gitleaks, and review `docs/design/` for personal details before going public.
**Why:** the repository may become public. **Scope:** one PR.
