# TODO

Issue-ready entries, roughly in build order. Delete an entry in the commit that finishes it.

## Hedwig for macOS

**What:** `apps/hedwig-mac` in SwiftUI: connect screen (server URL and key), per-account
inboxes, reading, replying, Gefilterd review. Decide between an XcodeGen `project.yml` and
a Swift package with a bundling script before starting. Raycast alias `email`.
**Why:** the primary mail app. **Scope:** several PRs, screen by screen.

## Deploy to Dobby

**What:** Dockerfile and Compose for the server, `tailscale serve` for HTTPS, nightly
encrypted backup of the database, deploy configuration in SOPS with age (recipients:
Gideon's Mac and Dobby). **Why:** run it at home. **Scope:** `infra/` plus a runbook topic.

## Routines, task queue and runners on clients

**What:** Portkey routines as data (trigger plus task type plus skill), the task queue, and
runners in client apps. Invoice processing is the first routine. **Why:** household
automation beyond mail. **Scope:** design note first.

## Open-source readiness

**What:** choose a licence, add GitHub Actions (format check, lint, typecheck, tests, hook
tests) and gitleaks, and review `docs/design/` for personal details before going public.
**Why:** the repository may become public. **Scope:** one PR.
