# 2026-10-22 Outings live in Hedwig, shared by the household

Gideon asked for concert and event cards on order mails, one click to keep them, tickets
attached automatically or by hand, and a page to manage every outing together with Eva.
The order mail rarely names the event the way you search for it ("90's party" versus a
mail from the ticket shop), and personalisation deadlines half a year later get missed.

## Decisions

- **In Hedwig, not a new Weasley Clock module.** Modules never import each other, and an
  outing needs mail at every step: reading the order, copying attachments as tickets,
  linking later mails and widening mail search. The calendar plan still puts calendar sync
  in its own module; the outing keeps `calendarEventId` for it.
- **Household-wide, not shared per item.** Pensieve shares one recording with one person;
  outings are joint by nature, so every person sees and changes every outing. Mail stays
  private: a linked mail in someone else's mailbox shows only that it exists and whose it is.
- **Called outings in code.** "Event" already means the server's event stream and soon
  calendar events; the apps say Evenement.
- **Detection without a model.** schema.org JSON-LD, ticket shops by domain, and regexes for
  order numbers, dates and the personalisation deadline. Cheap enough to run for every
  opened mail; the provider is asked for attachments only when the mail looks like an
  outing. A model can be added later for shops without structure.
- **Tickets are sensitive.** Facts-only keys get no ticket files or suggestions, MCP tools
  show only holder and status, nothing goes to a cloud model.
- **"In de agenda zetten" is a checklist item**, ticked by hand until calendar sync exists,
  instead of a button that pretends to write to the shared calendar.

## Built in parallel

A worktree agent built attachments on demand for all three providers (see
[the attachments entry](2026-10-22-attachments-keyed-by-part.md)) against an interface
fixed up front, while the outings were built on main; the merge was a fast-forward.
