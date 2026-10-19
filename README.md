# Burrow

Personal software to run a household, instead of a stack of SaaS subscriptions. Every
application is a helper from the Harry Potter universe, and they all share one home
server, one set of people and API keys, and one layer of routines and skills that AI
agents (Claude Code, Codex) can use.

| Name | What it is | Status |
|---|---|---|
| Server | Runs on Dobby, a small machine at home: the platform, its modules, people, keys, bots, MCP | Running |
| Hedwig | Mail: Gmail, Microsoft and Fastmail, with a bot that sorts it; a Mac app | Running |
| Pensieve | Recorded conversations: transcripts and notes; a Mac app | Running |
| Kreacher, Winky | Bots: a house-elf who sorts the mail, one who writes meeting notes | Running |
| Portkey | Routines: triggers that start tasks for the bots | Running |
| Patronus | A Telegram bot for both of us and the household group | Planned |

The design system and screens are in `docs/design/burrow-design-system.html`.

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
