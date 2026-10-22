---
id: 2026-10-22-outing-pictures-paste-anywhere
date: 2026-10-22
kind: decision
area: [hedwig]
topics: [outings]
---

# Outing pictures on the Mac, pasted anywhere on the page

The Mac shows the picture the server keeps for an outing: a thumbnail in the list and on
the mail card, a hero at the top of the page, and calm title colours when there is none.
Gideon chose the thumbnail over the colour strip, the colour band over the bare v2 header,
server-side fetching from mail and website, and no picture in the 09:00 notification.

Decisions:

- Pasting is the main way to set your own picture: copy it in Safari or Mail, select the
  outing, press ⌘V. A local key monitor (`PasteCatcher`) takes ⌘V in the window while no
  text field is being edited, because the detail pane is never first responder after a
  click in the list, so `onPasteCommand` would not fire. A Plak button does the same for
  mouse users.
- Dropping on the hero sets the picture; dropping anywhere else on the page still adds a
  ticket, as before, since screenshots are tickets.
- Image bytes win over a link: Safari puts both the TIFF and the image URL on the
  pasteboard, and the bytes work for pictures behind a login. A copied file wins over the
  bytes, because Finder adds the file's icon as an image.
- Formats the server does not take (TIFF, HEIC) are converted with ImageIO before the
  upload, and scaled down when they would pass the 8 MB limit.

Traps:

- `NSItemProvider(object: "https://…" as NSString)` also registers `public.url`, so a
  dropped text that is an address arrives as a URL too. Harmless here: both become a link.
- `scaledToFill()` inside a ZStack widens the layout; the picture goes in an overlay on
  `Color.clear` and is clipped.
- When testing with `hedwigctl`, ids from `find` go stale after a window resize; read
  them again before `press`, or another element gets pressed.
