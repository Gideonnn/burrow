---
id: 2026-10-22-evenementen-page-on-the-mac
date: 2026-10-22
kind: decision
area: [hedwig]
topics: [outings]
---

# The Evenementen page on the Mac, simple first

Hedwig got the Evenementen page from design v2: one status sentence per outing, three
facts, one checklist and the tickets, with everything else behind Details. The mail card
shrank to one line with Bekijk, or Bewaar for a mail Hedwig is unsure about.

Decisions:

- The status sentence and the sidebar badge live in HedwigCore (`OutingStatus.swift`)
  with `now` and the calendar as parameters, so the tests pin a date instead of building
  fixtures relative to today.
- An open item without a due date counts as due on the day of the outing; otherwise an
  undated "Oppas regelen" would never turn orange.
- Until Patronus exists, the Mac schedules local notifications, only for outings its own
  person goes to; otherwise both Macs would remind both people of everything.
- Missing tickets two weeks before count for the badge and say "Nog doen: kaarten
  toevoegen". A party without tickets therefore asks for them; rejected adding a
  "no tickets needed" flag until someone actually minds.

Traps:

- A SwiftUI `DatePicker` bound to `@State` with `.onChange(of:)` saving the value fires
  once on appear, when the state is set from the model. An empty Einde field saved its
  placeholder time. Save only from a `Binding` whose setter runs on user input.
- `UNUserNotificationCenter.current()` crashes a process without a bundle identifier
  (`swift run`, `swift test`), so scheduling sits in the app target behind a
  `Bundle.main.bundleIdentifier` check and the reminder list itself is computed in
  HedwigCore.
