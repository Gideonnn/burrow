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
- **Same Xcode as CI.** The `mac` CI job pins `DEVELOPER_DIR` to the Xcode the apps are
  built with locally, because each Swift release checks concurrency differently. When
  you move the local Xcode, bump the pin in `.github/workflows/ci.yml` in the same change.
- **Latency has a ceiling.** `apps/server/src/perf.test.ts` calls the routes the Macs
  lean on (rows, a title, similar, search, a shelf, the Zoeker, a person, the list, me,
  the outings, and a list change with its undo) 25 times each against the fixtures and
  fails when the 95th percentile passes the route's ceiling; the medians print in the
  test log. `infra/scripts/latency.sh` measures the same routes on the live server with
  `BURROW_SERVER` and `BURROW_KEY` from the environment, so a slow Dobby is seen before
  someone feels it.
