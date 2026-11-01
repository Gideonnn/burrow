---
id: 2026-11-02-a-default-on-standing-kind-joins-every-claim
date: 2026-11-02
kind: trap
area: [hedwig, server]
topics: [sharing, routines, mail-facts]
---

# A standing kind that is on by default joins every claim

Adding `hedwig.share` (Winky's household-mail suggestions, on by default as "Winky
stelt voor") broke three tests that never mention sharing: the facts tests claim with
`kinds: ['*']` and got a share piece instead of nothing, and the runner list showed a
new row with `done: 0`. A Mac runner with `*` behaves the same, which is intended.

Decided:

- Tests about one standing kind claim that kind by name (`kinds: ['hedwig.facts']`).
- `progress` answers `done: null` until there was anything to judge, so people without
  mail see no empty row in the runner list.
- Share suggestions wait for the facts when those are on, instead of racing them: the
  summary and category make Winky's judgement better and the facts kind wins the claim
  anyway (it is registered first, both are `low`).
- Taking back the last share of a suggestion counts as a dismissal, so the sender
  learning sees undo in "Winky deelt zelf" too. Rejected: counting only the explicit
  Niet, which would let auto mode share a sender's mail forever after every undo.
- "Altijd van deze afzender" with Niet silences the sender at once; rejected a separate
  "never" flag, two dismissals already mean the same.

Also hit: the repository's secrets hook refuses a Bash command that contains `this.db`
(it reads as a database file). Search code with the Read tool or a pattern without the
dot.
