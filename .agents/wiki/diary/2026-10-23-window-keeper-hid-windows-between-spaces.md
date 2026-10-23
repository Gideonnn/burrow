---
id: 2026-10-23-window-keeper-hid-windows-between-spaces
date: 2026-10-23
kind: trap
area: [hedwig, pensieve]
topics: []
---

# Keeping a window on screen hid it when it moved to another Space

`keepsWindowOnScreen()` (BurrowUI) also fitted the window on
`NSWindow.didChangeScreenNotification`, with an animated `setFrame`. Dragging Hedwig to
another Space in Mission Control reports a passing screen change; the animated move then
fought the Space transition and the window disappeared for a moment.

Decided: fit only when the window appears and after a sheet or alert ends, only when it is
visible, on the active Space, no mouse button is down and not in full screen, and without
animation. No fallback to `NSScreen.main` when `window.screen` is nil.

Rejected: keeping the screen observer with extra guards. macOS already keeps windows on
screen when displays change, and the observer was the only path that fired mid-move.
