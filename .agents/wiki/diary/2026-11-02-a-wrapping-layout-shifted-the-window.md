---
id: 2026-11-02-a-wrapping-layout-shifted-the-window
date: 2026-11-02
kind: trap
area: [apps]
topics: [search]
---

# A wrapping layout above a list shifted Hedwig's window under the toolbar

With the search header (plan chips and lenses in BurrowUI's `FlowLayout`) in a
`safeAreaInset` above the list, Hedwig's whole window content moved up under the
toolbar once an answer arrived. SwiftUI asks for the minimum size with width zero;
`FlowLayout` then puts every chip on its own line and reports that height, the column
cannot be that short, and the window lays its content out taller than itself.

Fixed by one sideways-scrolling line of chips. Before that, the header was a list row,
which keeps its first height, so the answer that arrives seconds later stayed hidden.
Also: `ForEach` over lenses with the same id (every year a period with one key) drew
the first one three times.
