---
id: 2026-10-23-ci-xcode-differs-from-local
date: 2026-10-23
kind: trap
area: [hedwig, repo]
topics: [testing]
---

# CI's Xcode differed from the local one

The `mac` CI job failed on every push for a day with `sending 'providers' risks causing
data races` in `OutingPictureViews.swift`, while `swift build` passed locally. The
`macos-26` runner image defaults to the newest Xcode (26.6, a newer Swift), which flags
sending the main actor's non-Sendable `[NSItemProvider]` to the nonisolated
`PastedContents.load`; the local Xcode 26.0.1 (Swift 6.2) did not.

Fix: `PastedContents.load` and its `NSItemProvider` helpers are
`nonisolated(nonsending)`, so they run on the caller's actor and nothing crosses an
isolation boundary. It compiles on both Xcodes.

Decided: the job pins `DEVELOPER_DIR` to the Xcode the apps are built and released with,
so green locally means green in CI. Bump the pin when the local Xcode moves. Rejected:
relaxing strict concurrency (hides real races) and following the image default (CI then
changes compiler under us without a commit).
