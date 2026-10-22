---
id: 2026-10-22-attachments-keyed-by-part
date: 2026-10-22
kind: trap
area: [hedwig, server]
topics: [providers]
---

# Attachments on demand, keyed by part

Hedwig lists and downloads attachments from every provider
(`MailProviderClient.attachments` and `attachment`), behind
`GET /api/messages/:id/attachments[/:attachmentId]`.

## Decided

- **Not stored on Dobby.** Each list and download goes to the provider. Storing would
  mean a second copy of every file, a backup that grows with the mail, and one more
  place where untrusted content sits. Rejected for now; a cache can come once a feature
  (event tickets) reads the same file often.
- **25 MB per download**, checked against the listed size before downloading and against
  the bytes after; the file passes through the server's memory.
- **Downloads are never rendered**: `content-disposition: attachment`, `nosniff` and a
  sandbox CSP, since an HTML attachment would otherwise run on the server's origin.

## Traps

- Gmail's `body.attachmentId` differs on every `messages.get` of the same message, so it
  cannot be an id a client keeps. The listed id is the `partId`; the download reads the
  message again for the current attachmentId.
- JMAP: two identical files on one email share a blobId, so the id is the `partId` there
  too.
- Hono's `c.body()` only takes `Uint8Array<ArrayBuffer>`; a provider's `Uint8Array` needs
  a cast (it is never shared memory).
