import type { DataOrigin, MediaType, VerdictKind } from '@burrow/contracts';
import { createdAt, id, people } from '@burrow/platform';
import { sql } from 'drizzle-orm';
import {
  index,
  integer,
  sqliteTable,
  text,
  uniqueIndex,
} from 'drizzle-orm/sqlite-core';

// A title on a list: the household's (no owner) or one person's. Rows are
// never deleted, only marked removed, so undo brings back the same row. The
// title is kept as a snapshot so a list still shows while the catalogue is
// down. `origin` keeps fixture titles apart from the real catalogue.
export const lumosListItems = sqliteTable(
  'lumos_list_items',
  {
    id: id(),
    ownerId: text('owner_id').references(() => people.id, {
      onDelete: 'cascade',
    }),
    mediaType: text('media_type').$type<MediaType>().notNull(),
    tmdbId: integer('tmdb_id').notNull(),
    origin: text('origin').$type<DataOrigin>().notNull(),
    seasons: text('seasons', { mode: 'json' }).$type<number[]>(),
    title: text('title').notNull(),
    year: integer('year'),
    poster: text('poster'),
    addedBy: text('added_by')
      .notNull()
      .references(() => people.id, { onDelete: 'cascade' }),
    addedAt: createdAt(),
    removedAt: integer('removed_at', { mode: 'timestamp_ms' }),
  },
  // SQLite treats NULLs as distinct in a unique index, so one index over a
  // nullable owner would let the shared list hold a title twice: shared and
  // personal rows each get their own partial index.
  (t) => [
    uniqueIndex('lumos_list_items_personal')
      .on(t.ownerId, t.mediaType, t.tmdbId, t.origin)
      .where(sql`${t.ownerId} is not null and ${t.removedAt} is null`),
    uniqueIndex('lumos_list_items_shared')
      .on(t.mediaType, t.tmdbId, t.origin)
      .where(sql`${t.ownerId} is null and ${t.removedAt} is null`),
  ],
);

// "Niet nu", "al gezien", "meer/minder zoals dit", for the household (no
// person) or one person. Undoing sets `undoneAt`; history stays.
export const lumosVerdicts = sqliteTable(
  'lumos_verdicts',
  {
    id: id(),
    personId: text('person_id').references(() => people.id, {
      onDelete: 'cascade',
    }),
    byId: text('by_id')
      .notNull()
      .references(() => people.id, { onDelete: 'cascade' }),
    mediaType: text('media_type').$type<MediaType>().notNull(),
    tmdbId: integer('tmdb_id').notNull(),
    origin: text('origin').$type<DataOrigin>().notNull(),
    kind: text('kind').$type<VerdictKind>().notNull(),
    reason: text('reason'),
    createdAt: createdAt(),
    undoneAt: integer('undone_at', { mode: 'timestamp_ms' }),
  },
  (t) => [index('lumos_verdicts_title').on(t.mediaType, t.tmdbId, t.origin)],
);

export type ChangeEffects = {
  listAdded: string[];
  listRemoved: string[];
  verdictsAdded: string[];
  verdictsUndone: string[];
};

// What one action did, so its author can undo exactly that.
export const lumosChanges = sqliteTable('lumos_changes', {
  id: id(),
  personId: text('person_id')
    .notNull()
    .references(() => people.id, { onDelete: 'cascade' }),
  effects: text('effects', { mode: 'json' }).$type<ChangeEffects>().notNull(),
  createdAt: createdAt(),
  undoneAt: integer('undone_at', { mode: 'timestamp_ms' }),
});

export type RequestStatus =
  | 'pending'
  | 'sent'
  | 'exists'
  | 'dropped'
  | 'failed';

// The outbox between a list entry and the media server: one row per title, so
// adding it twice or by two people asks Seerr at most once. A row is sent
// after a short grace period (undo stops it), retried with backoff, and never
// cancels or deletes anything at Seerr. Only the live catalogue writes here.
export const lumosRequests = sqliteTable(
  'lumos_requests',
  {
    id: id(),
    mediaType: text('media_type').$type<MediaType>().notNull(),
    tmdbId: integer('tmdb_id').notNull(),
    seasons: text('seasons', { mode: 'json' }).$type<number[]>(),
    status: text('status').$type<RequestStatus>().notNull(),
    seerrRequestId: integer('seerr_request_id'),
    attempts: integer('attempts').notNull().default(0),
    lastError: text('last_error'),
    nextAttemptAt: integer('next_attempt_at', { mode: 'timestamp_ms' }),
    requestedBy: text('requested_by')
      .notNull()
      .references(() => people.id, { onDelete: 'cascade' }),
    createdAt: createdAt(),
    updatedAt: integer('updated_at', { mode: 'timestamp_ms' }).notNull(),
  },
  (t) => [uniqueIndex('lumos_requests_title').on(t.mediaType, t.tmdbId)],
);
