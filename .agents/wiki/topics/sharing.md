# Sharing mail

The owner of a mail shares it with someone else in the household; that person can then
open it, fetch its attachments and find it in search, but never organize or answer it.
Winky reads recent mail on the owner's Mac and suggests household mail (energy, rent,
insurance, the house, holidays, joint appointments) to share; per person the setting
`hedwig.share` decides whether he only suggests or shares by himself. Code:
`modules/hedwig/src/server/sharing.ts`, contracts in `packages/contracts/src/sharing.ts`.

## Who sees what

- A share is the platform's `shares` row (module `hedwig`, item = message id).
- `canSeeMessage` (`modules/hedwig/src/server/access.ts`) lets in the owner's keys and
  the reading keys of everyone the mail is shared with, except facts-only keys and keys
  narrowed to some mailboxes. The read routes (`GET /api/messages/:id` and its
  attachments, `/search/ai/rank`) use it; actions, insights and sending keep
  `canSeeMailbox`, so the other person gets 404 there.
- Search adds the shared ids (`alsoIds`) only to a search everywhere: a mailbox, role
  or folder in the scope keeps it to the person's own mail.
- Every `MessageSummary` carries `share: { by, with }` (`by` is the owner when the mail
  is someone else's) and, for the owner, `shareSuggestion: { reason }`.

## Routes

```
POST   /api/messages/:id/share            { personId }      organize, owner only
DELETE /api/messages/:id/share/:personId                    organize, owner only
GET    /api/shared                        { withMe, byMe }
GET    /api/share/suggestions             { suggestions: [{ message, reason }] }
POST   /api/share/suggestions/:messageId  { decision: share | dismiss, always? }
```

Sharing with oneself or an unknown person is 400, like Pensieve.

## Winky's suggestions

- Standing work `hedwig.share` on the local queue, pinned to Winky's model, skill
  `household-share`, ten mails per piece, newest first. Eligible: mail of the last six
  months in inbox or archive, not category code, account, promotion or newsletter, not
  shared yet, not from a silenced sender, not judged yet (two failed attempts and a mail
  is left). Only for people whose `hedwig.share` is not `off` and who share the house
  with someone.
- With mail facts on, a mail waits for its facts first, so Winky judges with the summary
  and category; the facts kind is registered first and wins the claim.
- Verdicts live in `share_suggestions` (state `open`, `shared`, `dismissed`; null when
  Winky saw nothing). Per sender `share_senders` counts shared and dismissed:
  two dismissals silence the sender; `always` shares its suggestions by itself.
  `always` with dismiss silences at once. Taking back the last share of a suggestion
  counts as a dismissal and clears `always`.
- `hedwig.share`: `off` (Uit), `suggest` (Winky stelt voor, the default), `auto` (Winky
  deelt zelf: every suggestion is shared at once; the person can take it back).

## On the Mac

The reader shows "Gedeeld door …", Winky's suggestion with Deel, Niet and "Altijd van
deze afzender", or the button "Deel met …". Gedeeld under Overal lists the suggestions,
what others shared and what the person shared. Mail someone else shared is never marked
read and the toolbar's answer and organize buttons stay off for it.
