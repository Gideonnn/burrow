---
id: 2026-10-27-pull-to-refresh-on-the-mac
date: 2026-10-27
kind: trap
area: [hedwig, apps]
topics: []
---

# Pull to refresh on the Mac has no native control

Hedwig's list had `.refreshable` for months; on macOS it shows nothing and no gesture
starts it, and AppKit has no counterpart of `UIRefreshControl`.

The first try used SwiftUI's `onScrollGeometryChange` and `onScrollPhaseChange` and showed
nothing in Hedwig. A probe app showed why: the geometry does report a `List`'s offset, but
a `List` on the Mac is a `ListCoreScrollView` (an NSTableView inside), and the phase that
says the fingers are on the trackpad apparently never comes, so the pull never armed. A
plain SwiftUI `ScrollView` reported both.

`pullToRefresh` in BurrowUI therefore works in AppKit: a view behind the list finds the
NSScrollView covering the same part of the window, the fingers come from `NSEvent.phase`
in a local scroll monitor (momentum events have none), and the pull is how far the clip
view's bounds sit above `-contentInsets.top`. Past 50 pt and let go, the action runs with
a spinner row above the list. It works on macOS 14 too. `PullToRefreshState` holds the
decision and is unit tested, because the bounce back after letting go passes the
threshold a second time without fingers. The log category `app.burrow.ui`
`pull-to-refresh` notes the attach and each release with its distance, to tune the
threshold from a real trackpad.

Synthetic scroll events do not reach a `ListCoreScrollView`, neither through
`scrollWheel(with:)` nor `NSWindow.sendEvent`, so the gesture itself cannot be tested
headless; posting CGEvents takes over the operator's pointer.

Apple Mail on the Mac does have pull to refresh, but through its own private code; no
public AppKit or SwiftUI control exists. The look follows Mail: the system spinner
(`ProgressView()`, AppKit's spinning indicator) fading in as you pull and staying in a
64 pt gap above the list while refreshing.
