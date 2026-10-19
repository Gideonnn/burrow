import type {
  Address,
  MailFolder,
  MailProvider,
  Right,
  RoutineTrigger,
  ServerOp,
  TaskResult,
  TaskStatus,
  TaskWhere,
  TriageAction,
  TriageStatus,
} from '@burrow/contracts';
import type { ProviderMessage } from '@burrow/hedwig';
import { sql } from 'drizzle-orm';
import {
  index,
  integer,
  sqliteTable,
  text,
  uniqueIndex,
} from 'drizzle-orm/sqlite-core';

const id = () =>
  text('id')
    .primaryKey()
    .$defaultFn(() => crypto.randomUUID());
const createdAt = () =>
  integer('created_at', { mode: 'timestamp_ms' })
    .notNull()
    .default(sql`(unixepoch() * 1000)`);

export const people = sqliteTable('people', {
  id: id(),
  name: text('name').notNull(),
  // Lower-cased; the address the person logs in with through Cloudflare Access.
  email: text('email').unique(),
  createdAt: createdAt(),
});

export const mailboxes = sqliteTable('mailboxes', {
  id: id(),
  ownerId: text('owner_id')
    .notNull()
    .references(() => people.id),
  provider: text('provider').$type<MailProvider>().notNull(),
  address: text('address').notNull(),
  name: text('name').notNull(),
  // Provider credentials (OAuth tokens or an API token), encrypted with
  // BURROW_SECRET_KEY. Never returned by any route.
  credentials: text('credentials').notNull(),
  syncCursor: text('sync_cursor'),
  createdAt: createdAt(),
});

export const apiKeys = sqliteTable('api_keys', {
  id: id(),
  personId: text('person_id')
    .notNull()
    .references(() => people.id),
  name: text('name').notNull(),
  // SHA-256 of the token. Tokens carry 256 bits of randomness, so a fast hash
  // is enough; the plaintext is shown once when the key is created.
  hash: text('hash').notNull().unique(),
  prefix: text('prefix').notNull(),
  rights: text('rights', { mode: 'json' }).$type<Right[]>().notNull(),
  // null means every mailbox the person owns, including ones added later.
  mailboxIds: text('mailbox_ids', { mode: 'json' }).$type<string[] | null>(),
  lastUsedAt: integer('last_used_at', { mode: 'timestamp_ms' }),
  revokedAt: integer('revoked_at', { mode: 'timestamp_ms' }),
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

export const instructions = sqliteTable('instructions', {
  personId: text('person_id')
    .primaryKey()
    .references(() => people.id),
  text: text('text').notNull(),
});

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

export const routines = sqliteTable('routines', {
  id: id(),
  personId: text('person_id')
    .notNull()
    .references(() => people.id),
  name: text('name').notNull(),
  trigger: text('trigger', { mode: 'json' }).$type<RoutineTrigger>().notNull(),
  skill: text('skill').notNull(),
  bot: text('bot').notNull(),
  where: text('where').$type<TaskWhere>().notNull(),
  fallbackAfterHours: integer('fallback_after_hours'),
  approval: integer('approval', { mode: 'boolean' }).notNull(),
  enabled: integer('enabled', { mode: 'boolean' }).notNull(),
  lastRunAt: integer('last_run_at', { mode: 'timestamp_ms' }),
  createdAt: createdAt(),
});

export const tasks = sqliteTable(
  'tasks',
  {
    id: id(),
    routineId: text('routine_id')
      .notNull()
      .references(() => routines.id, { onDelete: 'cascade' }),
    personId: text('person_id')
      .notNull()
      .references(() => people.id),
    messageId: text('message_id').references(() => messages.id, {
      onDelete: 'set null',
    }),
    status: text('status').$type<TaskStatus>().notNull(),
    result: text('result', { mode: 'json' }).$type<TaskResult>(),
    error: text('error'),
    claimedBy: text('claimed_by'),
    claimedAt: integer('claimed_at', { mode: 'timestamp_ms' }),
    createdAt: createdAt(),
    updatedAt: integer('updated_at', { mode: 'timestamp_ms' })
      .notNull()
      .default(sql`(unixepoch() * 1000)`),
  },
  (t) => [index('tasks_person_status').on(t.personId, t.status)],
);
