---
name: lint
description: Run oxlint over the whole Burrow workspace. Use after code changes, or when asked to lint or fix lint issues.
---

# Lint

Run from the repository root; oxlint checks every package in one process.

```bash
pnpm lint          # report
pnpm lint:fix      # apply safe fixes
```

Configuration lives in `.oxlintrc.json`. Fix a finding in the code; disable a rule only
with a comment in the config that says why.
