---
id: 2026-10-27-pull-to-refresh-on-the-mac
date: 2026-10-27
kind: trap
area: [hedwig, apps]
topics: []
---

# Pull to refresh on the Mac has no native control

Hedwig's list had `.refreshable` for months; on macOS it shows nothing and no gesture
starts it, and AppKit has no counterpart of `UIRefreshControl`. `pullToRefresh` in
BurrowUI reads the elastic overscroll with `onScrollGeometryChange` and the fingers with
`onScrollPhaseChange` (both macOS 15; on 14 only ⌘R refreshes): past 64 pt and let go,
the action runs with a spinner row above the list. The decision lives in
`PullToRefreshState`, unit tested, because the bounce back after letting go passes the
threshold a second time without fingers.

Not verified by a synthetic gesture: posting CGEvent scroll phases takes over the
operator's pointer and picked the wrong window; the operator tries it on the trackpad.
