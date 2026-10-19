# The wiki

Agent-facing knowledge base with two kinds of page, kept apart:

- **`topics/`**: living reference. Current truth, rewritten freely, no dates in the prose.
- **`diary/`**: dated record, append-only. One file per event.

The test: would this sentence still be true in six months? Then it is a topic. Does it
describe a moment? Then it is a diary entry.

## The code always supersedes the wiki

When a page and the code disagree, the code is right and the page is a bug. Fix the page
in the same change.

## Diary entries

Filename is the id: `diary/YYYY-MM-DD-slug.md`. The slug names the finding, not the
activity. Front matter:

```markdown
---
id: 2026-10-19-burrow-founded
date: 2026-10-19
kind: decision        # decision | incident | trap | infra
area: [hedwig, server]
topics: [architecture]
---
```

Then: what happened, what it cost, what was decided and which alternatives were
rejected and why. Add a line to `diary/INDEX.md`, newest first.

## Topics

One subject per file, kebab-case. Start with a one-paragraph answer, then the detail.
Link from `INDEX.md`. Rules that change behaviour on every task belong in the root
`AGENTS.md`, with a link to the topic.
