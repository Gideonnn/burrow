---
id: 2026-10-23-reader-header-scrolls-with-the-mail
date: 2026-10-23
kind: decision
area: [hedwig, server]
topics: [providers]
---

# 2026-10-23 Hedwig's reader header scrolls with the mail, sized like Mail

Gideon compared Hedwig's reader with Apple Mail. Hedwig showed the subject as a big title
under a small sender line, and the header stayed fixed while only the mail scrolled. Now
the header follows Mail's order: a 44 pt avatar, the sender's name as the strongest line
(address on hover and in its context menu), the subject in regular weight, then compact
"Aan:", "Kopie:" and "Antwoord aan:" lines with bold labels and names. The date stays top
right; Mail's folder name and Details link were left out on purpose. Header, outing card,
review, summary and the remote-image offer scroll away together with the mail.

## Scrolling: one SwiftUI ScrollView, the web view as tall as its mail

The body is a `WKWebView` (`MailWebView`) inside the same `ScrollView` as the header,
framed at the mail's height. A user script in the `.defaultClient` content world measures
the body and an end marker with a `ResizeObserver` and posts the height. Page JavaScript
stays off: `allowsContentJavaScript = false` only affects the page's own world.

- Vertical wheel events and the scroll keys (space, shift-space, page up/down, home/end,
  arrows, ⌘↑/⌘↓) go to the outer `NSScrollView`. Horizontal wheel events stay in the web
  view for wide newsletters. Keys are left alone while a form field in the mail has focus;
  the script reports that too.
- Dragging a selection past the window edge calls `autoscroll(with:)`.
- Images that load later and window resizes change the body's size, so the observer
  posts a new height. Toggling remote images reloads the same view, which keeps its last
  height until the new one arrives.
- WebKit only paints the visible part of a tall web view: a long newsletter scrolled to
  the bottom showed no blank tiles. The WebContent process stayed around 200 MB.

**Trap:** the wrapper put `<meta>` and `<style>` before the mail's own doctype, so every
mail rendered in quirks mode. There, `height="100%"` tables resolve against the viewport.
Once the web view is as tall as the content, that locks the height: after a long mail, a
short one kept the long one's height. The wrapper now starts with the XHTML Transitional
doctype (almost-standards mode, which keeps the image-in-table-cell quirk mail relies on).
A trailing style forces `html, body { height: auto }`. Elements sized in `vh` would still
grow with the view; none were seen, so there is no guard for that.

Rejected:

- **Header inside the web view's scroll content** (insets or a subview): on macOS
  `WKWebView` has no public scroll view.
- **Header rendered in the HTML:** it loses the SwiftUI controls (Klopt, Geen spam,
  outing card, image offer). Making them work would need JavaScript in the page.
- **Header overlaid and moved by the page's scroll offset:** the offset arrives
  asynchronously from the web process, so the header would lag and jitter.

Hedwig has no find-in-page or zoom yet; with this layout they would have to scroll the
outer view, not the web view.

## Reply-To end to end

"Antwoord aan" needed data the server did not keep. `ProviderMessage.replyTo` now comes
from Gmail's `Reply-To` header, Graph's `replyTo` and JMAP's `replyTo`, and is stored in
`messages.reply_to` (migration 0021). It is null for mail synced before; `messageDetail`
returns `[]` then. The Mac shows the line only when Reply-To differs from the sender
(`RecipientLines`). Replying still goes to the sender, not to Reply-To.
