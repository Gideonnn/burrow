# Testing

Tests assert outcomes a user or caller can observe, not implementation details. Vitest
runs every TypeScript suite; `pnpm test` runs them through turbo.

## Rules

- **Red before green.** For a bug fix, write or run the test against the old code first
  and see it fail for the right reason; then fix. Mention the red run in the commit or PR.
- **Cheapest tier first.** Pure functions (like `serverOpsFor`) get unit tests. HTTP
  routes are tested in process with `app.request()`, no network. Provider clients are
  tested against recorded or hand-written fixtures, never against a real mailbox.
- **No real mail.** Fixtures use invented people and `example.com` addresses.
- **Quiet output.** Do not hide failures with `tail` or `grep` in CI; locally, keep the
  output short enough to read.
