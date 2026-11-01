import { z } from 'zod';
import { factCategory, messageFacts } from './facts';

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

// Who sees a message besides its owner. `by` is the owner when the message
// is someone else's, shared with the viewer.
export const messageShare = z.object({
  by: z.string().nullable(),
  with: z.array(z.string()),
});
export type MessageShare = z.infer<typeof messageShare>;

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
  // Null until the rules ran; a facts-only key gets an empty snippet.
  facts: messageFacts.nullable().default(null),
  share: messageShare.default({ by: null, with: [] }),
  // Winky thinks the household should see this; only its owner gets it.
  shareSuggestion: z.object({ reason: z.string() }).nullable().default(null),
});
export type MessageSummary = z.infer<typeof messageSummary>;

// The list filter, like Mail's: a message must match every criterion. "toMe"
// means the mailbox's own address is in To. Clients send "today" as `since`,
// because only they know where today starts.
export const messageFilter = z.enum([
  'unread',
  'flagged',
  'attachments',
  'toMe',
]);
export type MessageFilter = z.infer<typeof messageFilter>;

export const messageListQuery = z.object({
  folder: mailFolder.default('inbox'),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  before: z.iso.datetime().optional(),
  since: z.iso.datetime().optional(),
  // Comma-separated, as in `filter=unread,attachments`.
  filter: z
    .string()
    .transform((value) => value.split(',').filter(Boolean))
    .pipe(z.array(messageFilter))
    .optional(),
});
export type MessageListQuery = z.infer<typeof messageListQuery>;

// A folder without mail is left out of the counts.
export const folderCount = z.object({
  mailboxId: z.string(),
  folder: mailFolder,
  total: z.number().int(),
  unread: z.number().int(),
});
export type FolderCount = z.infer<typeof folderCount>;
export const folderCounts = z.array(folderCount);

// Who a reply goes to; the server works it out so every client agrees.
export const recipients = z.object({
  to: z.array(address),
  cc: z.array(address),
});
export type Recipients = z.infer<typeof recipients>;

export const messageDetail = messageSummary.extend({
  cc: z.array(address),
  replyTo: z.array(address).default([]),
  reply: recipients,
  replyAll: recipients,
  bodyText: z.string().nullable(),
  bodyHtml: z.string().nullable(),
});
export type MessageDetail = z.infer<typeof messageDetail>;

// A file on a message. The server fetches it from the provider when asked and
// never stores it; the id stays the same for the same message.
export const attachmentSummary = z.object({
  id: z.string(),
  name: z.string(),
  contentType: z.string(),
  size: z.number().int().nonnegative(),
  inline: z.boolean(),
});
export type AttachmentSummary = z.infer<typeof attachmentSummary>;

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
  // May stay empty for a reply: the server then addresses it like Reply.
  to: z.array(address).default([]),
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
  // People or organisations the mail is from or to ("Jan", "de tandarts");
  // the server looks them up among the people the person mails with.
  people: z.array(z.string().min(1)).max(4).default([]),
  from: z.string().nullable(),
  after: z.iso.date().nullable(),
  before: z.iso.date().nullable(),
  folder: mailFolder.nullable(),
  roles: z.array(mailboxRole).nullable(),
  unreadOnly: z.boolean(),
  hasAttachments: z.boolean(),
  // Only mail of these kinds ("facturen" is invoice); null for any.
  categories: z.array(factCategory).nullable().default(null),
  // Login codes and account notices are hidden unless asked for.
  includeLow: z.boolean().default(false),
  // The question asks for something the mail says ("wanneer komt de
  // monteur?"), not only for the mail itself.
  answer: z.boolean().default(false),
  explanation: z.string(),
});
export type SearchPlan = z.infer<typeof searchPlan>;

// Where the person searches: the mailbox, role or folder they have open.
// Left out, a search covers every mailbox the key sees.
export const searchScope = z.object({
  mailboxId: z.string().optional(),
  role: mailboxRole.optional(),
  folder: mailFolder.optional(),
});
export type SearchScope = z.infer<typeof searchScope>;

// What the search field's tokens add to the words: @people, a period, kinds
// of mail. A person is any of their addresses, or "@domain.example" for
// everyone at a domain, in From, To or Cc.
export const searchFilters = z.object({
  people: z.array(z.string().min(1)).max(20).default([]),
  after: z.iso.date().nullable().default(null),
  before: z.iso.date().nullable().default(null),
  categories: z.array(factCategory).nullable().default(null),
  hasAttachments: z.boolean().default(false),
  unreadOnly: z.boolean().default(false),
});
export type SearchFilters = z.infer<typeof searchFilters>;

const commaList = z.string().transform((value) =>
  value
    .split(',')
    .map((v) => v.trim())
    .filter(Boolean),
);

// The same filters as query parameters: `people=a@x.example,@y.example`,
// `kinds=invoice,order`, `attachments=true`.
export const searchFilterParams = z.object({
  people: commaList.pipe(z.array(z.string()).max(20)).optional(),
  after: z.iso.date().optional(),
  before: z.iso.date().optional(),
  kinds: commaList.pipe(z.array(factCategory)).optional(),
  attachments: z.stringbool().optional(),
  unread: z.stringbool().optional(),
});

export const aiSearchRequest = searchScope.extend({
  question: z.string().trim().min(1).max(500),
  includeLow: z.boolean().default(false),
  // Tokens the person already put in the field; the plan adds to them.
  filters: searchFilters.optional(),
  // The question's meaning from the embedding model on the person's Mac,
  // when it has one; the server then also searches by meaning.
  vector: z
    .object({ model: z.string(), values: z.array(z.number()).max(4096) })
    .optional(),
  // A plan from an earlier answer: run it again without asking the bot,
  // leaving out the parts named in `without`.
  plan: searchPlan.optional(),
  without: z.array(z.string()).max(20).default([]),
});
export type AiSearchRequest = z.infer<typeof aiSearchRequest>;

// Where a result matched: a piece of the body (or subject) with the matched
// words as [start, length] in UTF-16 units, so a client can bold them.
export const searchHit = z.object({
  field: z.enum(['subject', 'body', 'people', 'facts']),
  text: z.string(),
  ranges: z.array(z.tuple([z.number().int(), z.number().int()])),
});
export type SearchHit = z.infer<typeof searchHit>;

export const searchResult = messageSummary.extend({
  hit: searchHit.nullable().default(null),
});
export type SearchResult = z.infer<typeof searchResult>;

// A token the bot's plan stands for, shown in the field so the person sees
// and can change what was searched.
// `key` names the part of the plan a token stands for ("people:0", "period",
// "category:invoice", "group:1"); a client sends keys back in `without` to
// search again without them, no bot needed.
const tokenBase = { key: z.string(), label: z.string() };
export const searchToken = z.discriminatedUnion('kind', [
  z.object({
    ...tokenBase,
    kind: z.literal('person'),
    emails: z.array(z.string()),
  }),
  z.object({
    ...tokenBase,
    kind: z.literal('period'),
    after: z.iso.date().nullable(),
    before: z.iso.date().nullable(),
  }),
  z.object({
    ...tokenBase,
    kind: z.literal('category'),
    category: factCategory,
  }),
  z.object({ ...tokenBase, kind: z.literal('attachments') }),
  z.object({ ...tokenBase, kind: z.literal('unread') }),
  z.object({
    ...tokenBase,
    kind: z.literal('words'),
    words: z.array(z.string()),
  }),
]);
export type SearchToken = z.infer<typeof searchToken>;

export const searchResponse = z.object({
  // What the bot searched for, in the person's language; null for word search.
  explanation: z.string().nullable(),
  results: z.array(searchResult),
  // How many results matched in total, beyond the ones returned.
  total: z.number().int().default(0),
  // The bot's plan as tokens; empty for word search.
  tokens: z.array(searchToken).default([]),
  // The question asks for something the mail says; a client then asks
  // /search/ai/rank for the answer.
  wantsAnswer: z.boolean().default(false),
  // The bot's plan, to send back with `without` when a token is removed.
  plan: searchPlan.nullable().default(null),
  // No mail had every word, so these have the most of them: a question
  // typed before pressing Enter still shows something.
  loose: z.boolean().default(false),
  // A short answer to the question from the best results, with the ids it
  // rests on; null when the question asks for mail, not an answer.
  answer: z
    .object({ text: z.string(), messageIds: z.array(z.string()) })
    .nullable()
    .default(null),
});
export type SearchResponse = z.infer<typeof searchResponse>;

// The best results of a search by meaning, to be read by the bot: it orders
// them and, when asked, answers the question from them.
export const rankRequest = z.object({
  question: z.string().trim().min(1).max(500),
  messageIds: z.array(z.string()).min(1).max(30),
  answer: z.boolean().default(false),
});
export type RankRequest = z.infer<typeof rankRequest>;

export const rankResponse = z.object({
  // The same messages, the fitting ones first in the bot's order.
  results: z.array(searchResult),
  // How many of the results the bot found fitting.
  relevant: z.number().int(),
  answer: z
    .object({ text: z.string(), messageIds: z.array(z.string()) })
    .nullable(),
});
export type RankResponse = z.infer<typeof rankResponse>;

// Someone the person wrote to or heard from, for @name: every address under
// one name, how often mail went each way and when last.
export const mailPerson = z.object({
  name: z.string(),
  emails: z.array(z.string()),
  sent: z.number().int(),
  received: z.number().int(),
  lastAt: z.iso.datetime(),
  // A whole domain ("@school.example") rather than one person.
  domain: z.boolean().default(false),
});
export type MailPerson = z.infer<typeof mailPerson>;

export const peopleQuery = z.object({
  q: z.string().trim().max(100).default(''),
  limit: z.coerce.number().int().min(1).max(50).default(8),
});

export const peopleResponse = z.object({ people: z.array(mailPerson) });
export type PeopleResponse = z.infer<typeof peopleResponse>;
