import { z } from 'zod';

export const mailProvider = z.enum(['gmail', 'microsoft', 'fastmail']);
export type MailProvider = z.infer<typeof mailProvider>;

export const mailboxRole = z.enum(['private', 'work', 'school']);
export type MailboxRole = z.infer<typeof mailboxRole>;

export const mailFolder = z.enum(['inbox', 'archive', 'spam', 'trash', 'sent']);
export type MailFolder = z.infer<typeof mailFolder>;

export const address = z.object({
  name: z.string().optional(),
  email: z.string(),
});
export type Address = z.infer<typeof address>;

export const messageSummary = z.object({
  id: z.string(),
  mailboxId: z.string(),
  threadId: z.string().nullable(),
  from: address,
  to: z.array(address),
  subject: z.string(),
  snippet: z.string(),
  receivedAt: z.iso.datetime(),
  folder: mailFolder,
  unread: z.boolean(),
  flagged: z.boolean(),
  labels: z.array(z.string()),
  hasAttachments: z.boolean(),
});
export type MessageSummary = z.infer<typeof messageSummary>;

export const messageDetail = messageSummary.extend({
  cc: z.array(address),
  bodyText: z.string().nullable(),
  bodyHtml: z.string().nullable(),
});
export type MessageDetail = z.infer<typeof messageDetail>;

// Operations on a message at its provider. The server applies them through
// the provider API so phones see the same state as Hedwig.
export const serverOp = z.discriminatedUnion('op', [
  z.object({ op: z.literal('markRead') }),
  z.object({ op: z.literal('markUnread') }),
  z.object({ op: z.literal('moveToSpam') }),
  z.object({ op: z.literal('moveToInbox') }),
  z.object({ op: z.literal('archive') }),
  z.object({ op: z.literal('trash') }),
  z.object({ op: z.literal('flag') }),
  z.object({ op: z.literal('unflag') }),
  z.object({ op: z.literal('addLabel'), label: z.string().min(1) }),
  z.object({ op: z.literal('removeLabel'), label: z.string().min(1) }),
]);
export type ServerOp = z.infer<typeof serverOp>;

export const messageActionsRequest = z.object({
  ops: z.array(serverOp).min(1),
});

export const sendRequest = z.object({
  mailboxId: z.string(),
  to: z.array(address).min(1),
  cc: z.array(address).default([]),
  subject: z.string(),
  body: z.string(),
  // Set when replying; the server adds the threading headers.
  inReplyTo: z.string().optional(),
});
export type SendRequest = z.infer<typeof sendRequest>;

// The only things an agent may do to a message. Sending and deleting are
// deliberately absent: mail is untrusted input, so a crafted message can at
// worst make the agent sort it wrongly, never act on the outside world.
export const triageAction = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('keep') }),
  z.object({ kind: z.literal('spam') }),
  z.object({ kind: z.literal('archive') }),
  z.object({ kind: z.literal('needs-reply') }),
  z.object({ kind: z.literal('label'), label: z.string().min(1) }),
]);
export type TriageAction = z.infer<typeof triageAction>;

// A reply or new message prepared by a bot or an outside agent (through MCP).
// Only a person sends it, from the client.
export const draft = z.object({
  id: z.string(),
  mailboxId: z.string(),
  createdBy: z.string(),
  inReplyTo: z.string().nullable(),
  to: z.array(address),
  cc: z.array(address),
  subject: z.string(),
  body: z.string(),
  createdAt: z.iso.datetime(),
});
export type Draft = z.infer<typeof draft>;

export const createDraftRequest = z.object({
  mailboxId: z.string(),
  to: z.array(address).min(1),
  cc: z.array(address).default([]),
  subject: z.string(),
  body: z.string().min(1),
  inReplyTo: z.string().optional(),
});
export type CreateDraftRequest = z.infer<typeof createDraftRequest>;

// What the bot makes of a question like "de factuur van de tandarts in maart":
// groups of alternative words (a message matches a group when it contains any
// of them), plus filters. The bot never sees mail, only the question.
export const searchPlan = z.object({
  groups: z.array(z.array(z.string().min(1)).min(1)).max(6),
  from: z.string().nullable(),
  after: z.iso.date().nullable(),
  before: z.iso.date().nullable(),
  folder: mailFolder.nullable(),
  roles: z.array(mailboxRole).nullable(),
  unreadOnly: z.boolean(),
  hasAttachments: z.boolean(),
  explanation: z.string(),
});
export type SearchPlan = z.infer<typeof searchPlan>;

export const aiSearchRequest = z.object({
  question: z.string().trim().min(1).max(500),
});

export const searchResponse = z.object({
  // What the bot searched for, in the person's language; null for word search.
  explanation: z.string().nullable(),
  results: z.array(messageSummary),
});
export type SearchResponse = z.infer<typeof searchResponse>;
