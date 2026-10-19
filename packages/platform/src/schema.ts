import type {
  KeyRestrictions,
  Right,
  RoutineTrigger,
  SettingsValues,
  TaskResult,
  TaskStatus,
  TaskWhere,
} from '@burrow/contracts';
import { sql } from 'drizzle-orm';
import {
  index,
  integer,
  sqliteTable,
  text,
  uniqueIndex,
} from 'drizzle-orm/sqlite-core';

export const id = () =>
  text('id')
    .primaryKey()
    .$defaultFn(() => crypto.randomUUID());
export const createdAt = () =>
  integer('created_at', { mode: 'timestamp_ms' })
    .notNull()
    .default(sql`(unixepoch() * 1000)`);

export const people = sqliteTable('people', {
  id: id(),
  name: text('name').notNull(),
  // Lower-cased; the address the person logs in with through Cloudflare Access.
  email: text('email').unique(),
  // Household admins manage everyone's settings and devices, never content.
  admin: integer('admin', { mode: 'boolean' }).notNull().default(true),
  // Values for the settings modules declare; absent keys use the default.
  settings: text('settings', { mode: 'json' })
    .$type<SettingsValues>()
    .notNull()
    .default({}),
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
  // Per module, which of the person's things the key may see; see
  // keyRestrictions in the contracts.
  restrictions: text('restrictions', { mode: 'json' })
    .$type<KeyRestrictions>()
    .notNull()
    .default({}),
  lastUsedAt: integer('last_used_at', { mode: 'timestamp_ms' }),
  revokedAt: integer('revoked_at', { mode: 'timestamp_ms' }),
  createdAt: createdAt(),
});

// A person's standing instructions for every bot that works for them.
export const instructions = sqliteTable('instructions', {
  personId: text('person_id')
    .primaryKey()
    .references(() => people.id),
  text: text('text').notNull(),
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
    kind: text('kind').notNull().default('routine'),
    routineId: text('routine_id').references(() => routines.id, {
      onDelete: 'cascade',
    }),
    personId: text('person_id')
      .notNull()
      .references(() => people.id),
    // What the task is about, owned by a module; no foreign key, so a module
    // can remove its rows without the platform knowing the table.
    subjectType: text('subject_type'),
    subjectId: text('subject_id'),
    input: text('input', { mode: 'json' }).$type<Record<string, unknown>>(),
    status: text('status').$type<TaskStatus>().notNull(),
    where: text('where').$type<TaskWhere>().notNull().default('server'),
    // A client task nobody claimed moves to the server after this moment.
    fallbackAt: integer('fallback_at', { mode: 'timestamp_ms' }),
    result: text('result', { mode: 'json' }).$type<TaskResult>(),
    error: text('error'),
    attempts: integer('attempts').notNull().default(0),
    claimedBy: text('claimed_by'),
    claimedAt: integer('claimed_at', { mode: 'timestamp_ms' }),
    createdAt: createdAt(),
    updatedAt: integer('updated_at', { mode: 'timestamp_ms' })
      .notNull()
      .default(sql`(unixepoch() * 1000)`),
  },
  (t) => [
    index('tasks_person_status').on(t.personId, t.status),
    index('tasks_status').on(t.status),
    index('tasks_subject').on(t.subjectType, t.subjectId),
  ],
);

// An item a module owns, shared by its owner with another person.
export const shares = sqliteTable(
  'shares',
  {
    id: id(),
    module: text('module').notNull(),
    itemId: text('item_id').notNull(),
    personId: text('person_id')
      .notNull()
      .references(() => people.id),
    createdAt: createdAt(),
  },
  (t) => [uniqueIndex('shares_item_person').on(t.module, t.itemId, t.personId)],
);

// A file arriving in chunks; a module claims it once it is complete.
export const uploads = sqliteTable('uploads', {
  id: id(),
  personId: text('person_id')
    .notNull()
    .references(() => people.id),
  size: integer('size').notNull(),
  received: integer('received').notNull().default(0),
  createdAt: createdAt(),
});
