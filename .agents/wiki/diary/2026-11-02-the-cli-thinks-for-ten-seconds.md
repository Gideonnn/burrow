---
id: 2026-11-02-the-cli-thinks-for-ten-seconds
date: 2026-11-02
kind: trap
area: [server, platform]
topics: [search, architecture]
---

# The Claude CLI thinks for ten seconds, and "haiku" is Haiku 4.5

A search plan took 13 to 25 s on Dobby while a trivial call took 5.5 s. The CLI let
Haiku think: 1,324 output tokens for a ten-field plan (7,838 and 65 s without a schema).
With `MAX_THINKING_TOKENS=0` the same plan took 5.9 s and 344 tokens; `--effort low`
did not help (19 s). Requests can now say `thinking: false`; search does.

Also measured: with Claude Code 2.1.288, `--model haiku` runs `claude-haiku-4-5`, not
Haiku 5.5 as the architecture topic says. `--model claude-haiku-5-5` works (with an
`unrecognized_model` notice) and took 5.5 to 6.9 s. Every Kreacher task still runs on
4.5 with thinking; see TODO.

A second cause of slow searches: at most two agent runs at once, first come first
served, and opening a result starts reply suggestions on Opus. Searches are now
`urgent`: they skip the queue and have one place of their own.
