import type {
  FactCategory,
  FactPriority,
  Address,
  MailboxRole,
  MailFolder,
  MailProvider,
  ImageFrame,
  LineupArtist,
  OutingRead,
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
    // Null for mail stored before Reply-To was kept.
    replyTo: text('reply_to', { mode: 'json' }).$type<Address[]>(),
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

// What the rules, a template or a model found in a message; see the facts
// service. One row per message once the rules ran.
export const messageFacts = sqliteTable(
  'message_facts',
  {
    messageId: text('message_id')
      .primaryKey()
      .references(() => messages.id, { onDelete: 'cascade' }),
    personId: text('person_id')
      .notNull()
      .references(() => people.id),
    rulesVersion: integer('rules_version').notNull(),
    sensitive: integer('sensitive', { mode: 'boolean' }).notNull(),
    sensitiveKinds: text('sensitive_kinds', { mode: 'json' })
      .$type<string[]>()
      .notNull(),
    // code or account when a rule recognised noise; wins over any model.
    ruleCategory: text('rule_category').$type<FactCategory>(),
    category: text('category').$type<FactCategory>(),
    priority: text('priority').$type<FactPriority>(),
    summary: text('summary'),
    people: text('people', { mode: 'json' }).$type<string[]>().notNull(),
    organisations: text('organisations', { mode: 'json' })
      .$type<string[]>()
      .notNull(),
    amounts: text('amounts', { mode: 'json' })
      .$type<{ value: number; currency: string }[]>()
      .notNull(),
    dates: text('dates', { mode: 'json' }).$type<string[]>().notNull(),
    keywords: text('keywords', { mode: 'json' }).$type<string[]>().notNull(),
    source: text('source').$type<'rules' | 'template' | 'model'>().notNull(),
    // Sender and subject pattern, for mail a service sends again and again.
    templateKey: text('template_key'),
    templateId: text('template_id'),
    model: text('model'),
    modelAt: integer('model_at', { mode: 'timestamp_ms' }),
    modelAttempts: integer('model_attempts').notNull().default(0),
    modelError: text('model_error'),
    indexedAt: integer('indexed_at', { mode: 'timestamp_ms' }).notNull(),
  },
  (t) => [
    index('message_facts_person_model').on(t.personId, t.modelAt),
    index('message_facts_person_template').on(t.personId, t.templateKey),
  ],
);

// One answer for mail that repeats: a sender with a subject pattern.
export const messageTemplates = sqliteTable(
  'message_templates',
  {
    id: id(),
    personId: text('person_id')
      .notNull()
      .references(() => people.id),
    key: text('key').notNull(),
    members: integer('members').notNull(),
    category: text('category').$type<FactCategory>(),
    priority: text('priority').$type<FactPriority>(),
    summary: text('summary'),
    organisation: text('organisation'),
    keywords: text('keywords', { mode: 'json' }).$type<string[]>(),
    model: text('model'),
    factsAt: integer('facts_at', { mode: 'timestamp_ms' }),
    attempts: integer('attempts').notNull().default(0),
    createdAt: createdAt(),
  },
  (t) => [uniqueIndex('message_templates_person_key').on(t.personId, t.key)],
);

// An outing the household goes to, shared by everyone in it. Tickets live on
// disk under <data>/files/hedwig/outings/<id>/.
export const outings = sqliteTable(
  'outings',
  {
    id: id(),
    title: text('title').notNull(),
    kind: text('kind'),
    startsAt: integer('starts_at', { mode: 'timestamp_ms' }).notNull(),
    endsAt: integer('ends_at', { mode: 'timestamp_ms' }),
    doorsAt: integer('doors_at', { mode: 'timestamp_ms' }),
    allDay: integer('all_day', { mode: 'boolean' }).notNull().default(false),
    venue: text('venue'),
    address: text('address'),
    organiser: text('organiser'),
    vendor: text('vendor'),
    orderNumber: text('order_number'),
    url: text('url'),
    notes: text('notes').notNull().default(''),
    aliases: text('aliases', { mode: 'json' })
      .$type<string[]>()
      .notNull()
      .default([]),
    // Who goes; everyone in the household unless someone says otherwise.
    attendeeIds: text('attendee_ids', { mode: 'json' })
      .$type<string[]>()
      .notNull()
      .default([]),
    // Every name above in lower case, for mail search.
    searchText: text('search_text').notNull().default(''),
    calendarEventId: text('calendar_event_id'),
    inCalendar: integer('in_calendar', { mode: 'boolean' })
      .notNull()
      .default(false),
    // The picture above the outing, a file in its folder; imageOff when
    // someone chose none, so Hedwig does not pick one again.
    imageType: text('image_type'),
    imageSource: text('image_source').$type<'mail' | 'website' | 'upload'>(),
    imageAt: integer('image_at', { mode: 'timestamp_ms' }),
    imageFrame: text('image_frame', { mode: 'json' }).$type<ImageFrame>(),
    imageOff: integer('image_off', { mode: 'boolean' })
      .notNull()
      .default(false),
    createdBy: text('created_by')
      .notNull()
      .references(() => people.id),
    updatedBy: text('updated_by')
      .notNull()
      .references(() => people.id),
    createdAt: createdAt(),
    updatedAt: integer('updated_at', { mode: 'timestamp_ms' }).notNull(),
  },
  (t) => [index('outings_starts').on(t.startsAt)],
);

export const outingTickets = sqliteTable('outing_tickets', {
  id: id(),
  outingId: text('outing_id')
    .notNull()
    .references(() => outings.id, { onDelete: 'cascade' }),
  name: text('name').notNull(),
  contentType: text('content_type').notNull(),
  size: integer('size').notNull(),
  // File name inside the outing's folder.
  file: text('file').notNull(),
  holder: text('holder'),
  personalised: integer('personalised', { mode: 'boolean' })
    .notNull()
    .default(false),
  messageId: text('message_id').references(() => messages.id, {
    onDelete: 'set null',
  }),
  addedBy: text('added_by')
    .notNull()
    .references(() => people.id),
  addedAt: createdAt(),
});

export const outingTasks = sqliteTable('outing_tasks', {
  id: id(),
  outingId: text('outing_id')
    .notNull()
    .references(() => outings.id, { onDelete: 'cascade' }),
  kind: text('kind').$type<'personalise' | 'calendar' | 'custom'>().notNull(),
  title: text('title').notNull(),
  dueAt: integer('due_at', { mode: 'timestamp_ms' }),
  assigneeId: text('assignee_id').references(() => people.id),
  doneAt: integer('done_at', { mode: 'timestamp_ms' }),
  doneBy: text('done_by').references(() => people.id),
  createdAt: createdAt(),
});

// A festival's line-up as Haiku read it from the website; no row means no
// widget.
export const outingLineups = sqliteTable('outing_lineups', {
  outingId: text('outing_id')
    .primaryKey()
    .references(() => outings.id, { onDelete: 'cascade' }),
  status: text('status').$type<'working' | 'ready' | 'failed'>().notNull(),
  artists: text('artists', { mode: 'json' })
    .$type<LineupArtist[]>()
    .notNull()
    .default([]),
  complete: integer('complete', { mode: 'boolean' }).notNull().default(false),
  note: text('note'),
  error: text('error'),
  sources: text('sources', { mode: 'json' })
    .$type<string[]>()
    .notNull()
    .default([]),
  updatedAt: integer('updated_at', { mode: 'timestamp_ms' }).notNull(),
});

// Haiku's reading of a mail that looks like an outing, once per message.
export const outingReads = sqliteTable('outing_reads', {
  messageId: text('message_id')
    .primaryKey()
    .references(() => messages.id, { onDelete: 'cascade' }),
  answer: text('answer', { mode: 'json' }).$type<OutingRead>().notNull(),
  model: text('model').notNull(),
  createdAt: createdAt(),
});

export const outingMessages = sqliteTable(
  'outing_messages',
  {
    outingId: text('outing_id')
      .notNull()
      .references(() => outings.id, { onDelete: 'cascade' }),
    messageId: text('message_id')
      .notNull()
      .references(() => messages.id, { onDelete: 'cascade' }),
    createdAt: createdAt(),
  },
  (t) => [
    uniqueIndex('outing_messages_pair').on(t.outingId, t.messageId),
    index('outing_messages_message').on(t.messageId),
  ],
);
