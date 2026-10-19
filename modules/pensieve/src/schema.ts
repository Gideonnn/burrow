import type { MeetingNotes, RecordingStatus } from '@burrow/contracts';
import { createdAt, id, people } from '@burrow/platform';
import { sql } from 'drizzle-orm';
import {
  index,
  integer,
  real,
  sqliteTable,
  text,
} from 'drizzle-orm/sqlite-core';

// A recorded conversation. The audio lives on disk under
// <data>/files/pensieve/<id>/; transcript and notes live here so they can be
// searched.
export const recordings = sqliteTable(
  'recordings',
  {
    id: id(),
    ownerId: text('owner_id')
      .notNull()
      .references(() => people.id),
    title: text('title').notNull(),
    startedAt: integer('started_at', { mode: 'timestamp_ms' }).notNull(),
    durationSeconds: real('duration_seconds'),
    status: text('status').$type<RecordingStatus>().notNull(),
    error: text('error'),
    source: text('source').$type<'recorded' | 'imported'>().notNull(),
    // File names inside the recording's folder.
    original: text('original'),
    audio: text('audio'),
    audioBytes: integer('audio_bytes'),
    transcript: text('transcript'),
    notes: text('notes', { mode: 'json' }).$type<MeetingNotes>(),
    notesMarkdown: text('notes_markdown'),
    createdAt: createdAt(),
    updatedAt: integer('updated_at', { mode: 'timestamp_ms' })
      .notNull()
      .default(sql`(unixepoch() * 1000)`),
  },
  (t) => [index('recordings_owner_started').on(t.ownerId, t.startedAt)],
);
