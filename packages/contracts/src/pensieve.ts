import { z } from 'zod';
import { person } from './access';

// Where a recording is in its pipeline on the server. `stored` waits for the
// person to ask for a transcript (video and screen by default).
export const recordingStatus = z.enum([
  'compressing',
  'stored',
  'transcribing',
  'writing-notes',
  'done',
  'failed',
]);
export type RecordingStatus = z.infer<typeof recordingStatus>;

export const recordingKind = z.enum(['call', 'video', 'screen', 'dictation']);
export type RecordingKind = z.infer<typeof recordingKind>;

// Whether a kind is transcribed without being asked.
export const transcribesByDefault: Record<RecordingKind, boolean> = {
  call: true,
  video: false,
  screen: false,
  dictation: true,
};

// Seconds from the start of the recording.
const seconds = z
  .number()
  .min(0)
  .max(7 * 24 * 3600);

export const mark = z.object({
  at: seconds,
  note: z.string().trim().max(500).nullable().default(null),
});
export type Mark = z.infer<typeof mark>;

export const transcriptSegment = z.object({
  start: seconds,
  end: seconds,
  // "A", "B", … from the diarizing model; null without speaker recognition.
  speaker: z.string().nullable(),
  text: z.string(),
});
export type TranscriptSegment = z.infer<typeof transcriptSegment>;

export const label = z.object({
  id: z.string(),
  name: z.string(),
  // The person's visible recordings carrying it.
  count: z.number().int(),
});
export type Label = z.infer<typeof label>;

export const labelName = z.string().trim().min(1).max(60);
export const labelRequest = z.object({ name: labelName });
export const setLabelsRequest = z.object({
  labels: z.array(labelName).max(20),
});
export const setMarksRequest = z.object({ marks: z.array(mark).max(500) });

export const actionItem = z.object({
  text: z.string().min(1),
  owner: z.string().nullable().default(null),
  due: z.string().nullable().default(null),
});
export type ActionItem = z.infer<typeof actionItem>;

// What the notes skills return; the server renders the Markdown from it, so
// every set of notes looks the same and actions can become tasks later.
export const meetingNotes = z.object({
  title: z.string().max(120).nullable().default(null),
  summary: z.string().min(1).max(4_000),
  decisions: z.array(z.string()).default([]),
  actions: z.array(actionItem).default([]),
  openQuestions: z.array(z.string()).default([]),
});
export type MeetingNotes = z.infer<typeof meetingNotes>;

const at = seconds.nullable().default(null);

// An interview (video): the core, quotes worth keeping and chapters.
export const interviewNotes = z.object({
  title: z.string().max(120).nullable().default(null),
  summary: z.string().min(1).max(4_000),
  quotes: z
    .array(
      z.object({
        text: z.string().min(1),
        speaker: z.string().nullable().default(null),
        at,
      }),
    )
    .default([]),
  chapters: z.array(z.object({ title: z.string().min(1), at })).default([]),
});
export type InterviewNotes = z.infer<typeof interviewNotes>;

// A screen recording: what it shows, as steps someone can follow.
export const stepNotes = z.object({
  title: z.string().max(120).nullable().default(null),
  summary: z.string().min(1).max(4_000),
  steps: z.array(z.object({ text: z.string().min(1), at })).default([]),
});
export type StepNotes = z.infer<typeof stepNotes>;

// Notes as stored and served: tagged by type. Rows written before the tag
// existed are meeting notes.
export const recordingNotes = z.discriminatedUnion('type', [
  meetingNotes.extend({ type: z.literal('meeting') }),
  interviewNotes.extend({ type: z.literal('interview') }),
  stepNotes.extend({ type: z.literal('steps') }),
]);
export type RecordingNotes = z.infer<typeof recordingNotes>;
export type NotesType = RecordingNotes['type'];

export const recordingSummary = z.object({
  id: z.string(),
  kind: recordingKind,
  title: z.string(),
  owner: person,
  // True when the key's person owns it; otherwise it was shared with them.
  mine: z.boolean(),
  sharedWith: z.array(person),
  // The key's person's own labels on it.
  labels: z.array(z.string()),
  startedAt: z.iso.datetime(),
  durationSeconds: z.number().nullable(),
  status: recordingStatus,
  error: z.string().nullable(),
  source: z.enum(['recorded', 'imported']),
  audioBytes: z.number().nullable(),
  hasTranscript: z.boolean(),
  hasSegments: z.boolean(),
  hasNotes: z.boolean(),
  markCount: z.number().int(),
  // The first lines of the notes' summary, or of a dictation, for lists.
  preview: z.string().nullable(),
  updatedAt: z.iso.datetime(),
});
export type RecordingSummary = z.infer<typeof recordingSummary>;

export const recordingDetail = recordingSummary.extend({
  transcript: z.string().nullable(),
  segments: z.array(transcriptSegment).nullable(),
  marks: z.array(mark),
  notes: recordingNotes.nullable(),
  // Rendered from notes, or the Markdown an imported recording brought.
  notesMarkdown: z.string().nullable(),
});
export type RecordingDetail = z.infer<typeof recordingDetail>;

export const createRecordingRequest = z.object({
  uploadId: z.string(),
  kind: recordingKind.default('call'),
  title: z.string().trim().min(1).max(120),
  startedAt: z.iso.datetime().optional(),
  marks: z.array(mark).max(500).default([]),
  labels: z.array(labelName).max(20).default([]),
  // Overrides the kind's default (transcribesByDefault).
  transcribe: z.boolean().optional(),
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

export const redoRequest = z.object({
  step: z.enum(['transcript', 'notes', 'title']),
});

export const recordingTitle = z.object({
  title: z.string().trim().min(1).max(120),
});
