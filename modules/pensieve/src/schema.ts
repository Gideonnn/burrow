import type {
  Mark,
  RecordingKind,
  RecordingNotes,
  RecordingStatus,
  TranscriptSegment,
} from '@burrow/contracts';
import { createdAt, id, people } from '@burrow/platform';
import { sql } from 'drizzle-orm';
import {
  index,
  integer,
  primaryKey,
  real,
  sqliteTable,
  text,
  uniqueIndex,
} from 'drizzle-orm/sqlite-core';

// A recording. The audio lives on disk under <data>/files/pensieve/<id>/;
// transcript and notes live here so they can be searched. Video never comes
// here: the Mac keeps it and uploads only the audio.
export const recordings = sqliteTable(
  'recordings',
  {
    id: id(),
    ownerId: text('owner_id')
      .notNull()
      .references(() => people.id),
    kind: text('kind').$type<RecordingKind>().notNull().default('call'),
    title: text('title').notNull(),
    startedAt: integer('started_at', { mode: 'timestamp_ms' }).notNull(),
    durationSeconds: real('duration_seconds'),
    status: text('status').$type<RecordingStatus>().notNull(),
    error: text('error'),
    source: text('source').$type<'recorded' | 'imported'>().notNull(),
    // False leaves a compressed recording `stored` until the owner asks.
    transcribe: integer('transcribe', { mode: 'boolean' })
      .notNull()
      .default(true),
    // File names inside the recording's folder.
    original: text('original'),
    audio: text('audio'),
    audioBytes: integer('audio_bytes'),
    transcript: text('transcript'),
    segments: text('segments', { mode: 'json' }).$type<TranscriptSegment[]>(),
    marks: text('marks', { mode: 'json' })
      .$type<Mark[]>()
      .notNull()
      .default(sql`'[]'`),
    // Rows from before notes had a type hold meeting notes without one.
    notes: text('notes', { mode: 'json' }).$type<RecordingNotes>(),
    notesMarkdown: text('notes_markdown'),
    createdAt: createdAt(),
    updatedAt: integer('updated_at', { mode: 'timestamp_ms' })
      .notNull()
      .default(sql`(unixepoch() * 1000)`),
  },
  (t) => [index('recordings_owner_started').on(t.ownerId, t.startedAt)],
);

// A person's own labels. Free text, no colours; a person sees only theirs,
// also on recordings shared with them.
export const pensieveLabels = sqliteTable(
  'pensieve_labels',
  {
    id: id(),
    personId: text('person_id')
      .notNull()
      .references(() => people.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    createdAt: createdAt(),
  },
  (t) => [
    uniqueIndex('pensieve_labels_person_name').on(
      t.personId,
      sql`lower(${t.name})`,
    ),
  ],
);

export const recordingLabels = sqliteTable(
  'recording_labels',
  {
    recordingId: text('recording_id')
      .notNull()
      .references(() => recordings.id, { onDelete: 'cascade' }),
    labelId: text('label_id')
      .notNull()
      .references(() => pensieveLabels.id, { onDelete: 'cascade' }),
  },
  (t) => [
    primaryKey({ columns: [t.recordingId, t.labelId] }),
    index('recording_labels_label').on(t.labelId),
  ],
);
