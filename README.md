# Burrow

Personal software to run a household, instead of a stack of SaaS subscriptions. Every
application is a helper from the Harry Potter universe, and they all share one home
server, one set of people and API keys, and one layer of routines and skills that AI
agents (Claude Code, Codex) can use.

| Name | What it is | Status |
|---|---|---|
| Server | Runs on Dobby, a small machine at home: keys, people, bots, MCP | Skeleton |
| Kreacher | The first bot: a house-elf who sorts the mail, defined in `bots/kreacher.md` | Draft |
| Hedwig | Mail: Gmail, Microsoft and Fastmail, with an agent that triages | Started |
| Sorting Hat | The triage skill agents use to sort mail | Draft |
| Portkey | Routines: triggers that start a task | Planned |

Burrow is not affiliated with or endorsed by Warner Bros. or J.K. Rowling; the names
are a private theme.

## Development

```bash
pnpm install
pnpm dev:server     # server on http://127.0.0.1:4717
pnpm test
pnpm lint && pnpm typecheck && pnpm format:check
```

Agents start with [AGENTS.md](AGENTS.md).
