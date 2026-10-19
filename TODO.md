# TODO

Issue-ready entries, roughly in build order. Delete an entry in the commit that finishes it.

## First deploy on Dobby (operator)

**What:** the one-time steps in the deploy topic: SSH alias and host key, Docker on
Dobby, the SOPS-encrypted environment, `tailscale serve`, the agent logins in the
container, `cli init`, and the backup timer with its age recipients.
**Why:** the artifacts exist and CI builds and starts the image, but only Gideon can
create the secrets and change Dobby.
**Scope:** about an hour, following `.agents/wiki/topics/deploy.md`.

## Runner and Taken view in Hedwig

**What:** a "Taken" list in Hedwig with approve and reject, and a runner in the app that
claims client tasks while it is open and runs them with the local `claude` (absolute
path, since GUI apps do not inherit the shell PATH).
**Why:** the server side exists; clients cannot run or review tasks yet.
**Scope:** one PR in `apps/hedwig-mac`.

## Invoice routine

**What:** a skill that reads an invoice (fields, PDF attachment), files it and proposes a
line for the bookkeeping, run as a client routine with a server fallback. Needs
attachment download in the providers and a decision about the bookkeeping package.
**Why:** chosen by Gideon as the first household routine; deferred on purpose.
**Scope:** design note first.

## Open-source readiness

**What:** choose a licence, add GitHub Actions (format check, lint, typecheck, tests, hook
tests) and gitleaks, and review `docs/design/` for personal details before going public.
**Why:** the repository may become public. **Scope:** one PR.
