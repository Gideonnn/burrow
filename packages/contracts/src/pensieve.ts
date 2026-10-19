import { z } from 'zod';
import { person } from './access';

// Where a recording is in its pipeline on the server.
export const recordingStatus = z.enum([
  'compressing',
  'transcribing',
  'writing-notes',
  'done',
  'failed',
]);
export type RecordingStatus = z.infer<typeof recordingStatus>;

export const actionItem = z.object({
  text: z.string().min(1),
  owner: z.string().nullable().default(null),
  due: z.string().nullable().default(null),
});
export type ActionItem = z.infer<typeof actionItem>;

// What the notes skill returns; the server renders the Markdown from it, so
// every set of notes looks the same and actions can become tasks later.
export const meetingNotes = z.object({
  title: z.string().max(120).nullable().default(null),
  summary: z.string().min(1).max(4_000),
  decisions: z.array(z.string()).default([]),
  actions: z.array(actionItem).default([]),
  openQuestions: z.array(z.string()).default([]),
});
export type MeetingNotes = z.infer<typeof meetingNotes>;

export const recordingSummary = z.object({
  id: z.string(),
  title: z.string(),
  owner: person,
  // True when the key's person owns it; otherwise it was shared with them.
  mine: z.boolean(),
  sharedWith: z.array(person),
  startedAt: z.iso.datetime(),
  durationSeconds: z.number().nullable(),
  status: recordingStatus,
  error: z.string().nullable(),
  source: z.enum(['recorded', 'imported']),
  audioBytes: z.number().nullable(),
  hasTranscript: z.boolean(),
  hasNotes: z.boolean(),
  // The first lines of the notes' summary, for lists.
  preview: z.string().nullable(),
  updatedAt: z.iso.datetime(),
});
export type RecordingSummary = z.infer<typeof recordingSummary>;

export const recordingDetail = recordingSummary.extend({
  transcript: z.string().nullable(),
  notes: meetingNotes.nullable(),
  // Rendered from notes, or the Markdown an imported recording brought.
  notesMarkdown: z.string().nullable(),
});
export type RecordingDetail = z.infer<typeof recordingDetail>;

export const createRecordingRequest = z.object({
  uploadId: z.string(),
  title: z.string().trim().min(1).max(120),
  startedAt: z.iso.datetime().optional(),
  // An import from RecHoarder brings what it already had; the server then
  // skips those steps.
  transcript: z.string().max(2_000_000).optional(),
  notesMarkdown: z.string().max(200_000).optional(),
  source: z.enum(['recorded', 'imported']).default('recorded'),
});
export type CreateRecordingRequest = z.infer<typeof createRecordingRequest>;

export const updateRecordingRequest = z.object({
  title: z.string().trim().min(1).max(120),
});

export const shareRequest = z.object({ personId: z.string() });

export const redoRequest = z.object({ step: z.enum(['transcript', 'notes']) });
