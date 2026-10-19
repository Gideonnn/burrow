---
name: test
description: Run the Burrow test suites with vitest. Use after code changes, when fixing a bug (red before green) or when asked to run tests.
---

# Test

```bash
pnpm test                                   # every package through turbo
pnpm --filter @burrow/server test           # one package
pnpm --filter @burrow/server exec vitest    # watch mode while working
./.agents/hooks/test-hooks.sh               # the repository hooks
```

Follow [testing](../../wiki/topics/testing.md): show a failing test before the fix, use
invented fixtures, never a real mailbox.
