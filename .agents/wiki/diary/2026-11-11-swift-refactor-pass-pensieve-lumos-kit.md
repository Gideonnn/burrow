---
id: 2026-11-11-swift-refactor-pass-pensieve-lumos-kit
date: 2026-11-11
kind: decision
area: [pensieve, lumos, burrow-kit]
topics: [architecture, pensieve, lumos]
---

# A detail wraps its summary

A refactor pass over Pensieve, Lumos and BurrowKit, same behaviour with less code.

- `RecordingDetail` and `TitleDetail` repeated every field of their summary type, and
  Lumos rebuilt the summary by hand. Each now decodes its summary from the same JSON and
  reads it through `@dynamicMemberLookup` (`detail.title` still works). `TitleDetail`
  keeps the page's own fields in `TitleDetail.Extra`, read the same way. Both are
  `Decodable` only: nothing encodes them.
- Pensieve's `VideoProfile` and `EncodeSettings` held the same three numbers; the presets
  live on `EncodeSettings`. Outbox and Shelf share `RecordFolder` for their JSON.
- BurrowKit gained the pieces each app model wrote itself: `ConnectionStore.initial(_:environment:)`
  for `<APP>_SERVER`/`<APP>_KEY`, `APIClient.answers()` for the reachability probe,
  `ServerReachability.events(from:)` and `message(for:quiet:)`, and `Binding.isPresent()`.
  Pensieve and Lumos use them; Hedwig and Hogsmeade can follow.
- Removed as unused: `LocalSetting` (the `settings` command no longer lists an always
  empty `local`), the palette tokens no Mac app draws with, `BurrowColor.module`,
  `deleteRunner`, `Profile.enabled`.

Rejected: splitting `LumosModel` into files, because its stored properties cannot move
into extensions and the split would only make private state internal; one shared
`RootView` in BurrowUI, while Hedwig and Hogsmeade were being reworked in parallel.
