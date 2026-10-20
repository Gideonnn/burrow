import type {
  Address,
  MailboxRole,
  MailFolder,
  MailProvider,
  ServerOp,
  TriageAction,
  TriageStatus,
} from '@burrow/contracts';
import { createdAt, id, people } from '@burrow/platform';
import {
  index,
  integer,
  sqliteTable,
  text,
  uniqueIndex,
} from 'drizzle-orm/sqlite-core';
import type { ProviderMessage } from '../provider';

export const mailboxes = sqliteTable('mailboxes', {
  id: id(),
  ownerId: text('owner_id')
    .notNull()
    .references(() => people.id),
  provider: text('provider').$type<MailProvider>().notNull(),
  role: text('role').$type<MailboxRole>().notNull().default('private'),
  // Extra bot instructions for mail in this mailbox, next to the person's own.
  instructions: text('instructions').notNull().default(''),
  address: text('address').notNull(),
  name: text('name').notNull(),
  // Where the person put it in the sidebar, lowest first.
  position: integer('position').notNull().default(0),
  // Provider credentials (OAuth tokens or an API token), encrypted with
  // BURROW_SECRET_KEY. Never returned by any route.
  credentials: text('credentials').notNull(),
  syncCursor: text('sync_cursor'),
  // Where bringing in older mail continues, and when it finished.
  backfillCursor: text('backfill_cursor'),
  backfilledAt: integer('backfilled_at', { mode: 'timestamp_ms' }),
  createdAt: createdAt(),
});

export const messages = sqliteTable(
  'messages',
  {
    id: id(),
    mailboxId: text('mailbox_id')
      .notNull()
      .references(() => mailboxes.id, { onDelete: 'cascade' }),
    providerId: text('provider_id').notNull(),
    threadId: text('thread_id'),
    from: text('from', { mode: 'json' }).$type<Address>().notNull(),
    to: text('to', { mode: 'json' }).$type<Address[]>().notNull(),
    cc: text('cc', { mode: 'json' }).$type<Address[]>().notNull(),
    subject: text('subject').notNull(),
    snippet: text('snippet').notNull(),
    bodyText: text('body_text'),
    bodyHtml: text('body_html'),
    receivedAt: integer('received_at', { mode: 'timestamp_ms' }).notNull(),
    folder: text('folder').$type<MailFolder>().notNull(),
    unread: integer('unread', { mode: 'boolean' }).notNull(),
    flagged: integer('flagged', { mode: 'boolean' }).notNull(),
    labels: text('labels', { mode: 'json' }).$type<string[]>().notNull(),
    hasAttachments: integer('has_attachments', { mode: 'boolean' }).notNull(),
    headers: text('headers', { mode: 'json' })
      .$type<ProviderMessage['headers']>()
      .notNull(),
    // Set once triage has looked at the message, so a restart never
    // triages the same mail twice.
    triagedAt: integer('triaged_at', { mode: 'timestamp_ms' }),
    triageAttempts: integer('triage_attempts').notNull().default(0),
    createdAt: createdAt(),
  },
  (t) => [
    uniqueIndex('messages_mailbox_provider').on(t.mailboxId, t.providerId),
    index('messages_mailbox_folder_received').on(
      t.mailboxId,
      t.folder,
      t.receivedAt,
    ),
  ],
);

export const triageLog = sqliteTable(
  'triage_log',
  {
    id: id(),
    messageId: text('message_id')
      .notNull()
      .references(() => messages.id, { onDelete: 'cascade' }),
    personId: text('person_id')
      .notNull()
      .references(() => people.id),
    bot: text('bot').notNull(),
    action: text('action', { mode: 'json' }).$type<TriageAction>().notNull(),
    reason: text('reason').notNull(),
    unsure: integer('unsure', { mode: 'boolean' }).notNull(),
    ops: text('ops', { mode: 'json' }).$type<ServerOp[]>().notNull(),
    status: text('status').$type<TriageStatus>().notNull(),
    reviewedAt: integer('reviewed_at', { mode: 'timestamp_ms' }),
    createdAt: createdAt(),
  },
  (t) => [index('triage_log_person_status').on(t.personId, t.status)],
);

export const learnedRules = sqliteTable('learned_rules', {
  id: id(),
  personId: text('person_id')
    .notNull()
    .references(() => people.id),
  text: text('text').notNull(),
  createdAt: createdAt(),
});

export const drafts = sqliteTable('drafts', {
  id: id(),
  mailboxId: text('mailbox_id')
    .notNull()
    .references(() => mailboxes.id, { onDelete: 'cascade' }),
  // Name of the key (or bot) that prepared it, shown in the client.
  createdBy: text('created_by').notNull(),
  inReplyTo: text('in_reply_to').references(() => messages.id, {
    onDelete: 'set null',
  }),
  to: text('to', { mode: 'json' }).$type<Address[]>().notNull(),
  cc: text('cc', { mode: 'json' }).$type<Address[]>().notNull(),
  subject: text('subject').notNull(),
  body: text('body').notNull(),
  createdAt: createdAt(),
});

export const messageInsights = sqliteTable('message_insights', {
  messageId: text('message_id')
    .primaryKey()
    .references(() => messages.id, { onDelete: 'cascade' }),
  bot: text('bot').notNull(),
  summary: text('summary'),
  replies: text('replies', { mode: 'json' })
    .$type<{ label: string; body: string }[]>()
    .notNull(),
  createdAt: createdAt(),
});
