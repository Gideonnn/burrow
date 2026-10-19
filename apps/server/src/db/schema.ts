import type { MailProvider, Right } from '@burrow/contracts';
import { sql } from 'drizzle-orm';
import { integer, sqliteTable, text } from 'drizzle-orm/sqlite-core';

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
