---
id: 2026-10-23-replies-go-to-reply-to
date: 2026-10-23
kind: decision
area: [hedwig, server]
topics: [mcp]
---

# 2026-10-23 Replies go to Reply-To, decided by the server

Gideon asked for standard reply addressing now that the server keeps Reply-To. Reply
answers the Reply-To addresses, else the sender. Reply all adds the original To and keeps
the original Cc in Cc; the owner's own addresses and doubles drop out, compared without
case. On mail the owner sent, Reply goes to its recipients (as Apple Mail does), and a
note to self answers the owner. Forward is unchanged.

The rule lives once, in `modules/hedwig/src/reply.ts` (`replyRecipients`). The server
puts its outcome in every message detail as `reply` and `replyAll`, so Hedwig's Reply
buttons, the reply suggestions ("Stel antwoorden voor" fills a Reply) and agents reading
`get_message` agree. A draft with `inReplyTo` and an empty `to` (REST, MCP
`create_draft`, `burrowctl hedwig draft` without `to=`) is addressed like Reply, and a
routine's drafted reply always is, whatever address the model wrote. "Own addresses" are
all mailboxes of the mailbox's owner, not only those the key sees, so a reply all from
the home mailbox also drops the work address.

Rejected: the same rule written twice, in Swift and TypeScript. Two copies drift; the
Mac now only falls back to the sender when an older server sends no `reply`.

Mail stored before migration 0021 has `reply_to` null and still answers the sender;
fetching Reply-To on demand needs a single-message call on every provider client, so it
is a TODO entry.
