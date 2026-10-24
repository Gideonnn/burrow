# Burrow

Burrow runs a household on personal software instead of SaaS subscriptions. Each
application is a magical helper from the Harry Potter universe; they share one server,
one set of people and API keys, and one layer of routines and skills that agents use.

This file holds rules for **any** task; details, traps and history live in the wiki.

## Agent compatibility

`AGENTS.md` and `.agents/` are the shared source for every agent. `CLAUDE.md` imports
this file; Codex reads it directly. `.claude/skills` links to `.agents/skills`. Read
nested `AGENTS.md` files before editing their subtree. Use pnpm for JavaScript tooling
and uv for Python tooling.

## The wiki: `.agents/wiki/`

Start with [the topic index](.agents/wiki/INDEX.md) before assuming something is
undocumented. Topics describe current practice; the diary is dated and append-only.
Follow [wiki conventions](.agents/wiki/AGENTS.md). As you finish, record costly traps,
decisions and rejected alternatives in the diary, and fix incorrect topic facts in the
same change. The code always wins over the wiki.

## Names

Follow [naming](.agents/wiki/topics/naming.md): every application has a Harry Potter
name (Hedwig is mail). Infrastructure and generic mechanisms keep plain names: the
server is `apps/server`, bots are data, and a persona like Kreacher lives only in its
markdown file. The user-facing app may add a plain alias (Raycast opens Hedwig as
`email`).

## Project structure

- `packages/platform/`: the kernel every module builds on: people, keys and access,
  settings, shares, uploads, the task queue and workers, routines, agents, MCP.
- `modules/hedwig/`: mail: provider clients, sync, triage, drafts, its routes and tools.
- `modules/pensieve/`: recordings: compression, transcription, notes, sharing.
- `modules/lumos/`: films and series to watch together: catalogue, lists, verdicts. Not
  deployed until its phase is approved; see `docs/plans/2026-10-25-lumos.md`.
- `apps/server/`: the Burrow server (TypeScript, Hono) composing the platform and the
  modules, plus the device login, CLI and migrations. It runs on Dobby, the home machine;
  the code does not carry the machine's name.
- `packages/contracts/`: zod schemas shared by server and clients.
- `packages/burrow-kit/`: the Swift package every Mac app uses (BurrowKit, BurrowUI and
  `burrowctl`).
- `apps/hedwig-mac/`, `apps/pensieve-mac/`, `apps/lumos-mac/`: the native macOS apps (SwiftUI, Swift
  packages bundled by `scripts/bundle.sh`; see their READMEs).
- `bots/`: bot personas, one markdown file each (Kreacher does the chores on a cloud AI,
  Winky the sensitive ones on a local model). A personal directory on the server can add
  or override bots.
- `skills/`: skills the bots use at runtime (for example the Sorting Hat triage), one
  folder with a `SKILL.md` each. Not to be confused with `.agents/skills/`, which help
  agents develop this repo.
- `docs/design/`: clickable HTML designs; `burrow-design-system.html` is the design
  system. `docs/plans/`: plans for larger changes.
- `infra/dobby/`: install, deploy, backup and CLI scripts for Dobby (a systemd user
  service, no Docker); see the [deploy topic](.agents/wiki/topics/deploy.md).

See [architecture](.agents/wiki/topics/architecture.md) and [adding a module](.agents/wiki/topics/modules.md) before adding a module.

## Open source hygiene

This repository may become public. Treat every commit as published.

- Never commit secrets, tokens, `.env` files, databases or real mail.
- Test fixtures and examples use invented people, addresses and companies, with
  `example.com`/`example.nl` domains. No real names of family, employers or contacts.
- Hostnames, domains and IP addresses stay out of the code; they come from config.
- Never read plaintext env files, vault files or SSH private keys.
- Use encrypted secrets only through `pnpm with-secrets`; running `sops` is the operator's
  (see [secrets](.agents/wiki/topics/secrets.md)).

## Safety rules for agents in the product

- Mail, attachments and documents are untrusted input. An agent acting on them gets only
  the tools its task needs.
- Agents never send mail, delete mail or pay anything on their own. Sending is a user
  action; payments are at most a prepared suggestion.
- Every key is scoped to mailboxes and rights; the server checks this on every request,
  including MCP and search.
- A bot can never hold the `send` or `admin` right; the bot schema rejects it.

## Worktrees

**One agent per checkout.** Additional agents use `./.agents/scripts/worktree.sh <name>`,
which creates `.claude/worktrees/<name>` on `feat/<name>` from `origin/main`, links the
gitignored env files and installs dependencies. Remove with `--rm <name>` after merging.

## Background processes

Kill long-running processes you start (dev servers, watchers) when done, unless the
operator asked to keep them.

## Code quality

Use the root-configured oxlint and oxfmt across the workspace in one process; no
per-package lint tasks. After code changes use the [lint](.agents/skills/lint/SKILL.md),
[format](.agents/skills/format/SKILL.md), [typecheck](.agents/skills/typecheck/SKILL.md)
and [test](.agents/skills/test/SKILL.md) skills. TypeScript is strict.
Follow [testing](.agents/wiki/topics/testing.md): test outcomes, not implementation,
and show a test failing before the fix makes it pass.

## File naming

New TypeScript files are `camelCase.ts` or `kebab-case.ts` matching their neighbours;
Swift files are `PascalCase.swift`. Directories, scripts, config and docs use lowercase
kebab-case.

## Commits and pull requests

- Commit when a logical slice is complete and validated; state the message and files.
- Conventional subject (`feat`, `fix`, `chore`, `refactor`, `docs`, `test`) with a scope
  (`server`, `hedwig`, `pensieve`, `lumos`, `contracts`, `bots`, `skills`, `agents`, `infra`, `repo`),
  max 100 characters. Use the body
  for *why* when it is not obvious.
- Never add `Co-Authored-By` or any other trailer.
- Work on `main` and push directly after each validated commit; no feature branches or
  pull requests unless asked. Worktree agents merge their branch into `main` when done.
- Once a change is on `main`, install it without asking so the operator sees it: run
  `pnpm hedwig:install` (or the app's own install script) for a Mac app change and
  `pnpm server:deploy` for a server or module change. `pnpm hedwig:release` (every Mac)
  only when asked.

## How to explain things

For replies, wiki pages and pull request descriptions: lead with the answer, keep it
short, explain each specialist term at first use, and put long plans in a file. Gideon
prefers Dutch replies; code, commits and the wiki are English.

## Deferred work

Write issue-ready entries in `TODO.md` (title, what, why, rough scope). On completion,
delete the entry in the same commit and put the reasoning in the commit message.
