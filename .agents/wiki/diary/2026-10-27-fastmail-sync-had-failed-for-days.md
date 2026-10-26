---
id: 2026-10-27-fastmail-sync-had-failed-for-days
date: 2026-10-27
kind: trap
area: [hedwig, server]
topics: [providers, deploy]
---

# 2026-10-27 The Fastmail sync had failed for days: `asText` on List-Unsubscribe

Dobby's server log held nine thousand lines of `sync gideon@spierings.io failed: g:
invalidArguments` and seven hundred failed backfills, found while reading the log for
something else during the platform review. Fastmail answers `invalidArguments` for the
Email/get property `header:List-Unsubscribe:asText`: to Fastmail a List-* header is a
URL header, and `asText` is not accepted on it, whatever RFC 8621 says about `asText`
being allowed on any header. The fake JMAP server in the tests accepted anything, so the
suite was green.

- **Fix:** `header:List-Unsubscribe:asRaw`, which every server allows and which keeps
  the string the parser expects. The fake now refuses `asText` on List-* headers.
- **Why nobody saw it:** the Gmail mailbox kept syncing, the Mac shows no sync errors,
  and the log line said only `g: invalidArguments`: Fastmail names the offending
  argument in `arguments`, not in `description`, and the client did not print it.
  Errors now print the arguments too.
- **Next:** a mailbox that fails every round for an hour should show on the Mac and
  reach Gideon (the sidebar's connection badge, or a Kreacher note); in `TODO.md`.
- Also seen in the log: Gmail backfill hits the per-minute quota (`403 Quota exceeded`)
  and waits ten minutes, as designed; the sync loop itself is fine.
