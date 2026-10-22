import { mkdir, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import {
  type CreateRecordingRequest,
  interviewNotes,
  type Mark,
  meetingNotes,
  type RecordingDetail,
  type RecordingKind,
  type RecordingNotes,
  type RecordingStatus,
  type RecordingSummary,
  stepNotes,
  type TaskPriority,
  type TaskResult,
  transcribesByDefault,
} from '@burrow/contracts';
import {
  type Access,
  listPeople,
  type Platform,
  botRequest,
  type TaskKind,
  type TaskRow,
  untrusted,
} from '@burrow/platform';
import { and, desc, eq, inArray, like, or } from 'drizzle-orm';
import { z } from 'zod';
import { type Audio, STORED_EXTENSION } from './audio';
import { LabelError, Labels } from './labels';
import {
  hasNotes,
  NOTES_SKILLS,
  NOTES_TYPE,
  renderNotes,
  typedNotes,
} from './notes';
import { recordings } from './schema';
import { stamp, timestamped, toSrt } from './subtitles';
import { joinParts, type Transcriber, type Transcription } from './transcribe';

export const MODULE = 'pensieve';
const MAX_TRANSCRIPT = 400_000;

const NOTES_SCHEMAS = {
  call: meetingNotes,
  video: interviewNotes,
  screen: stepNotes,
} as const;
const NOTES_JSON = {
  call: z.toJSONSchema(meetingNotes, { target: 'draft-7' }),
  video: z.toJSONSchema(interviewNotes, { target: 'draft-7' }),
  screen: z.toJSONSchema(stepNotes, { target: 'draft-7' }),
};
const NOTES_TASK = {
  call: 'Write the notes of this recorded conversation',
  video: 'Write the notes of this recorded interview',
  screen: 'Write the steps this screen recording shows',
};

export class RecordingError extends Error {}

export type RecordingRow = typeof recordings.$inferSelect;

export type RecordingsOptions = {
  platform: Platform;
  audio: Audio;
  // Without one, transcription fails with a reason people can act on.
  transcriber?: Transcriber;
  // The bot that writes notes; it needs every notes skill.
  bot: string;
};

export type RecordingFilter = {
  scope?: 'all' | 'mine' | 'shared';
  kind?: RecordingKind;
  // Any of these (OR), among the key's person's own labels.
  labels?: string[];
};

const step = (row: RecordingRow) => ({ type: 'recording', id: row.id });

// Someone waits to paste a dictation.
const priorityOf = (row: RecordingRow): TaskPriority =>
  row.kind === 'dictation' ? 'urgent' : 'normal';

const GENERIC_TITLE =
  /^(opname|recording|standup|meeting|gesprek|dictaat|dictation|video|scherm|screen)$/i;

// Recordings and their pipeline: compress the upload, transcribe it, write
// the notes. Each step is a task on the platform's workers, so it survives a
// restart, retries, and shows up in the apps as work in progress.
export class Recordings {
  readonly labels: Labels;

  constructor(private readonly o: RecordingsOptions) {
    const bot = o.platform.catalog.bots.get(o.bot);
    for (const skill of Object.values(NOTES_SKILLS)) {
      if (!bot?.skills.includes(skill)) {
        throw new RecordingError(`bot "${o.bot}" needs the ${skill} skill`);
      }
    }
    this.labels = new Labels(() => this.db);
  }

  private get db() {
    return this.o.platform.db;
  }

  dir(id: string) {
    return this.o.platform.files.path(MODULE, id);
  }

  audioPath(row: RecordingRow) {
    return row.audio ? join(this.dir(row.id), row.audio) : undefined;
  }

  // --- people -------------------------------------------------------------

  async create(access: Access, request: CreateRecordingRequest) {
    const { platform } = this.o;
    if (!platform.settings.enabled(access.personId, 'pensieve.enabled')) {
      throw new RecordingError('Pensieve is switched off for this person');
    }
    const id = crypto.randomUUID();
    const dir = this.dir(id);
    await mkdir(dir, { recursive: true });
    try {
      await platform.uploads.take(
        request.uploadId,
        access.personId,
        join(dir, 'original'),
      );
    } catch (error) {
      await rm(dir, { recursive: true, force: true });
      throw new RecordingError((error as Error).message);
    }
    const notes = request.notesMarkdown?.trim() || null;
    const row = this.db
      .insert(recordings)
      .values({
        id,
        ownerId: access.personId,
        kind: request.kind,
        title: request.title,
        startedAt: request.startedAt ? new Date(request.startedAt) : new Date(),
        status: 'compressing',
        source: request.source,
        transcribe: request.transcribe ?? transcribesByDefault[request.kind],
        original: 'original',
        transcript: request.transcript?.trim() || null,
        marks: sortMarks(request.marks),
        notesMarkdown: notes,
      })
      .returning()
      .get();
    if (request.labels.length) {
      this.labels.set(access.personId, row.id, request.labels);
    }
    platform.workers.enqueue({
      kind: 'pensieve.compress',
      personId: row.ownerId,
      subject: step(row),
      priority: priorityOf(row),
    });
    this.changed(row);
    return this.summary(row, access);
  }

  private visibleRows(access: Access, filter: RecordingFilter = {}) {
    const scope = filter.scope ?? 'all';
    const shared = this.o.platform.shares.sharedWith(MODULE, access.personId);
    const mine = eq(recordings.ownerId, access.personId);
    const theirs = shared.length ? inArray(recordings.id, shared) : undefined;
    const where =
      scope === 'mine'
        ? mine
        : scope === 'shared'
          ? (theirs ?? eq(recordings.id, ''))
          : theirs
            ? or(mine, theirs)
            : mine;
    let rows = this.db
      .select()
      .from(recordings)
      .where(filter.kind ? and(where, eq(recordings.kind, filter.kind)) : where)
      .orderBy(desc(recordings.startedAt))
      .all();
    if (filter.labels?.length) {
      const labelled = this.labels.recordingsWith(
        access.personId,
        filter.labels,
      );
      rows = rows.filter((r) => labelled.has(r.id));
    }
    return rows;
  }

  list(access: Access, filter: RecordingFilter = {}) {
    return this.summaries(this.visibleRows(access, filter), access);
  }

  search(
    access: Access,
    query: string,
    filter: RecordingFilter = {},
    limit = 20,
  ) {
    const visible = this.visibleRows(access, filter).map((r) => r.id);
    if (!visible.length) return [];
    const pattern = `%${query.replace(/[%_]/g, '')}%`;
    const labelled = [...this.labels.matching(access.personId, query)].filter(
      (id) => visible.includes(id),
    );
    const rows = this.db
      .select()
      .from(recordings)
      .where(
        and(
          inArray(recordings.id, visible),
          or(
            like(recordings.title, pattern),
            like(recordings.transcript, pattern),
            like(recordings.notesMarkdown, pattern),
            like(recordings.marks, pattern),
            labelled.length ? inArray(recordings.id, labelled) : undefined,
          ),
        ),
      )
      .orderBy(desc(recordings.startedAt))
      .limit(limit)
      .all();
    return this.summaries(rows, access);
  }

  // Undefined when the key's person neither owns it nor had it shared.
  find(access: Access, id: string): RecordingRow | undefined {
    const row = this.row(id);
    return row && this.visible(access, row) ? row : undefined;
  }

  visible(access: Access, row: RecordingRow) {
    return (
      row.ownerId === access.personId ||
      this.o.platform.shares.of(MODULE, row.id).includes(access.personId)
    );
  }

  owned(access: Access, id: string): RecordingRow {
    const row = this.row(id);
    if (!row || row.ownerId !== access.personId) {
      throw new RecordingError('not found');
    }
    return row;
  }

  rename(access: Access, id: string, title: string) {
    const row = this.update(this.owned(access, id).id, { title });
    return this.summary(row, access);
  }

  setMarks(access: Access, id: string, marks: Mark[]) {
    const row = this.update(this.owned(access, id).id, {
      marks: sortMarks(marks),
    });
    return this.detail(row, access);
  }

  // Labels are the person's own, so someone a recording was shared with can
  // label it too without the owner seeing.
  setLabels(access: Access, id: string, names: string[]) {
    const row = this.find(access, id);
    if (!row) throw new RecordingError('not found');
    this.labels.set(access.personId, row.id, names);
    this.o.platform.events.emitTo([access.personId], {
      type: 'recording.changed',
      recordingId: row.id,
      status: row.status,
    });
    return this.summary(row, access);
  }

  listLabels(access: Access) {
    return this.labels.list(
      access.personId,
      this.visibleRows(access).map((r) => r.id),
    );
  }

  addLabel(access: Access, name: string) {
    const label = this.labels.ensure(access.personId, name);
    return this.listLabels(access).find((l) => l.id === label.id)!;
  }

  renameLabel(access: Access, id: string, name: string) {
    try {
      const label = this.labels.rename(access.personId, id, name);
      return this.listLabels(access).find((l) => l.id === label.id)!;
    } catch (error) {
      if (error instanceof LabelError) throw new RecordingError(error.message);
      throw error;
    }
  }

  removeLabel(access: Access, id: string) {
    try {
      this.labels.remove(access.personId, id);
    } catch (error) {
      if (error instanceof LabelError) throw new RecordingError(error.message);
      throw error;
    }
  }

  async remove(access: Access, id: string) {
    const row = this.owned(access, id);
    // Who it was shared with hears that it is gone before the shares go.
    this.changed(row, 'recording.removed');
    this.o.platform.shares.removeItem(MODULE, row.id);
    this.db.delete(recordings).where(eq(recordings.id, row.id)).run();
    await rm(this.dir(row.id), { recursive: true, force: true });
  }

  share(access: Access, id: string, personId: string) {
    const row = this.owned(access, id);
    if (personId === row.ownerId) {
      throw new RecordingError('a recording is already its owner’s');
    }
    if (!listPeople(this.db).some((p) => p.id === personId)) {
      throw new RecordingError('unknown person');
    }
    this.o.platform.shares.share(MODULE, row.id, personId);
    this.changed(row);
    return this.summary(row, access);
  }

  unshare(access: Access, id: string, personId: string) {
    const row = this.owned(access, id);
    this.changed(row);
    this.o.platform.shares.unshare(MODULE, row.id, personId);
    return this.summary(row, access);
  }

  // "Maak transcript": a stored recording goes on to transcription and
  // notes. Asking twice is harmless.
  requestTranscript(access: Access, id: string) {
    const row = this.owned(access, id);
    if (row.transcribe && row.status !== 'stored') {
      return this.summary(row, access);
    }
    const updated = this.update(row.id, { transcribe: true });
    if (updated.audio && updated.status === 'stored') this.next(updated);
    return this.summary(this.row(row.id)!, access);
  }

  redo(access: Access, id: string, which: 'transcript' | 'notes') {
    const row = this.owned(access, id);
    if (!row.audio) throw new RecordingError('the audio is not ready yet');
    if (which === 'transcript') {
      this.next(
        this.update(row.id, {
          transcribe: true,
          transcript: null,
          segments: null,
          notes: null,
          notesMarkdown: null,
        }),
      );
    } else {
      if (!hasNotes(row.kind)) {
        throw new RecordingError('a dictation has no notes');
      }
      if (!row.transcript) throw new RecordingError('there is no transcript');
      this.next(this.update(row.id, { notes: null, notesMarkdown: null }));
    }
    return this.summary(this.row(row.id)!, access);
  }

  subtitles(row: RecordingRow) {
    return row.segments?.length ? toSrt(row.segments) : undefined;
  }

  // --- the pipeline -------------------------------------------------------

  taskKinds(): TaskKind[] {
    const about = (t: TaskRow) => this.row(t.subjectId ?? '');
    const named = (label: string) => (t: TaskRow) => ({
      title: `${label}: ${about(t)?.title ?? 'opname'}`,
    });
    return [
      {
        name: 'pensieve.compress',
        describe: named('Comprimeren'),
        attempts: 2,
        run: (t) => this.compress(this.taskRow(t)),
        failed: (t, error) => this.failed(t, error),
      },
      {
        name: 'pensieve.transcribe',
        describe: named('Transcriberen'),
        attempts: 3,
        run: (t) => this.transcribe(this.taskRow(t)),
        failed: (t, error) => this.failed(t, error),
      },
      {
        name: 'pensieve.notes',
        describe: (t) => {
          const kind = about(t)?.kind;
          return {
            ...named(
              kind === 'screen' ? 'Stappen schrijven' : 'Notulen schrijven',
            )(t),
            bot: this.o.bot,
            skill: NOTES_SKILLS[kind && hasNotes(kind) ? kind : 'call'],
          };
        },
        agent: {
          request: (t) => this.notesRequest(this.taskRow(t)),
          accept: (t, raw) => this.acceptNotes(this.taskRow(t), raw),
        },
        failed: (t, error) => this.failed(t, error),
      },
    ];
  }

  private async compress(row: RecordingRow): Promise<TaskResult> {
    const dir = this.dir(row.id);
    const audio = `audio.${STORED_EXTENSION}`;
    let { audioBytes, durationSeconds } = row;
    if (row.original) {
      const { seconds } = await this.o.audio.compress(
        join(dir, row.original),
        join(dir, audio),
      );
      durationSeconds = seconds;
      audioBytes = (await stat(join(dir, audio))).size;
      await rm(join(dir, row.original), { force: true });
    }
    const next = this.update(row.id, {
      audio,
      audioBytes,
      durationSeconds,
      original: null,
    });
    this.next(next);
    return result(
      `Gecomprimeerd tot ${((audioBytes ?? 0) / 1_048_576).toFixed(1)} MB.`,
    );
  }

  private async transcribe(row: RecordingRow): Promise<TaskResult> {
    const { transcriber, platform } = this.o;
    if (!transcriber) {
      throw new Error(
        'Transcriberen staat uit: zet OPENAI_API_KEY in de instellingen van de server.',
      );
    }
    const path = this.audioPath(row);
    if (!path) throw new Error('the audio is not ready');
    const parts = join(this.dir(row.id), 'parts');
    await rm(parts, { recursive: true, force: true });
    await mkdir(parts, { recursive: true });
    try {
      const files = await this.o.audio.split(
        path,
        parts,
        transcriber.maxSeconds,
      );
      const language = platform.settings.get(row.ownerId, 'pensieve.language');
      const speakers =
        row.kind !== 'dictation' &&
        platform.settings.enabled(row.ownerId, 'pensieve.speakers');
      const options = {
        language: typeof language === 'string' ? language : 'nl',
        speakers,
        // Subtitles for video and screen; speakers come with timestamps.
        timestamps: row.kind === 'video' || row.kind === 'screen' || speakers,
      };
      const done: { start: number; transcription: Transcription }[] = [];
      for (const part of files) {
        done.push({
          start: part.start,
          transcription: await transcriber.transcribe(part.file, options),
        });
      }
      const { text, segments } = joinParts(done);
      if (!text) throw new Error('the transcript came back empty');
      const title =
        row.kind === 'dictation' && GENERIC_TITLE.test(row.title.trim())
          ? firstWords(text)
          : row.title;
      this.next(this.update(row.id, { transcript: text, segments, title }));
      return result(`Getranscribeerd: ${text.split(/\s+/).length} woorden.`);
    } finally {
      await rm(parts, { recursive: true, force: true });
    }
  }

  private notesRequest(row: RecordingRow) {
    if (!hasNotes(row.kind)) throw new Error('a dictation has no notes');
    const { catalog } = this.o.platform;
    const bot = catalog.bots.get(this.o.bot)!;
    const owner = this.o.platform.owner(row.ownerId);
    const minutes = row.durationSeconds
      ? `${Math.round(row.durationSeconds / 60)} minutes`
      : 'unknown';
    const transcript = (
      row.segments?.length ? timestamped(row.segments) : (row.transcript ?? '')
    ).slice(0, MAX_TRANSCRIPT);
    const marks = row.marks.length
      ? row.marks
          .map((m) => `- ${stamp(m.at)}${m.note ? ` ${m.note}` : ''}`)
          .join('\n')
      : '(none)';
    return {
      ...botRequest(bot, [catalog.skills.get(NOTES_SKILLS[row.kind])!]),
      timeoutMs: 15 * 60_000,
      prompt: `${NOTES_TASK[row.kind]} for ${owner.name}.

## ${owner.name}'s instructions
${owner.instructions.trim() || '(none)'}

## Recording facts (from the server, trustworthy)
- Title: ${row.title}
- Recorded: ${row.startedAt.toISOString()}
- Duration: ${minutes}
- Recorded by: ${owner.name}
- Timestamps in the transcript: ${row.segments?.length ? 'yes, [mm:ss] from the start' : 'none; leave every "at" null'}

## Moments ${owner.name} marked while recording
${untrusted('untrusted_marks', marks)}

## Transcript (untrusted, what people said)
${untrusted('untrusted_transcript', transcript)}

Answer with JSON only, matching the schema. Write the notes in ${owner.language}.`,
      schema: NOTES_JSON[row.kind],
    };
  }

  private acceptNotes(row: RecordingRow, raw: unknown): TaskResult {
    if (!hasNotes(row.kind)) throw new Error('a dictation has no notes');
    const parsed = NOTES_SCHEMAS[row.kind].parse(raw);
    const notes = { ...parsed, type: NOTES_TYPE[row.kind] } as RecordingNotes;
    const { language } = this.o.platform.owner(row.ownerId);
    const updated = this.update(row.id, {
      notes,
      notesMarkdown: renderNotes(notes, language),
      title:
        notes.title && GENERIC_TITLE.test(row.title.trim())
          ? notes.title
          : row.title,
      status: 'done',
      error: null,
    });
    this.o.platform.routines.fire('recording', row.ownerId, step(updated), {
      recording: updated,
    });
    const fields: Record<string, string> =
      notes.type === 'meeting'
        ? {
            Besluiten: String(notes.decisions.length),
            Actiepunten: String(notes.actions.length),
          }
        : notes.type === 'interview'
          ? {
              Citaten: String(notes.quotes.length),
              Hoofdstukken: String(notes.chapters.length),
            }
          : { Stappen: String(notes.steps.length) };
    return result(notes.summary, fields);
  }

  // Decides what comes after the step that just finished.
  private next(row: RecordingRow) {
    const { platform } = this.o;
    let status: RecordingStatus = 'done';
    let kind: string | undefined;
    if (!row.transcript) {
      if (row.transcribe) {
        status = 'transcribing';
        kind = 'pensieve.transcribe';
      } else {
        status = 'stored';
      }
    } else if (
      hasNotes(row.kind) &&
      !row.notesMarkdown &&
      platform.settings.enabled(row.ownerId, 'pensieve.notes')
    ) {
      status = 'writing-notes';
      kind = 'pensieve.notes';
    }
    const updated = this.update(row.id, { status, error: null });
    if (kind) {
      platform.workers.enqueue({
        kind,
        personId: row.ownerId,
        subject: step(updated),
        priority: priorityOf(updated),
      });
    }
  }

  private failed(t: TaskRow, error: string) {
    const row = this.row(t.subjectId ?? '');
    if (row) this.update(row.id, { status: 'failed', error });
  }

  // --- helpers ------------------------------------------------------------

  row(id: string) {
    return this.db.select().from(recordings).where(eq(recordings.id, id)).get();
  }

  private taskRow(t: TaskRow): RecordingRow {
    const row = this.row(t.subjectId ?? '');
    if (!row) throw new Error('the recording was deleted');
    return row;
  }

  private update(id: string, values: Partial<RecordingRow>): RecordingRow {
    const row = this.db
      .update(recordings)
      .set({ ...values, updatedAt: new Date() })
      .where(eq(recordings.id, id))
      .returning()
      .get();
    if (!row) throw new RecordingError('the recording was deleted');
    this.changed(row);
    return row;
  }

  private changed(row: RecordingRow, type = 'recording.changed') {
    this.o.platform.events.emitTo(
      [row.ownerId, ...this.o.platform.shares.of(MODULE, row.id)],
      { type, recordingId: row.id, status: row.status },
    );
  }

  private summaries(rows: RecordingRow[], access: Access) {
    const labels = this.labels.namesFor(
      access.personId,
      rows.map((r) => r.id),
    );
    const people = new Map(listPeople(this.db).map((p) => [p.id, p.name]));
    return rows.map((r) => this.summary(r, access, labels, people));
  }

  summary(
    row: RecordingRow,
    access: Access,
    labels = this.labels.namesFor(access.personId, [row.id]),
    people = new Map(listPeople(this.db).map((p) => [p.id, p.name])),
  ): RecordingSummary {
    const named = (id: string) => ({ id, name: people.get(id) ?? '?' });
    const preview =
      row.notes?.summary ??
      (row.kind === 'dictation' ? row.transcript : null) ??
      null;
    return {
      id: row.id,
      kind: row.kind,
      title: row.title,
      owner: named(row.ownerId),
      mine: row.ownerId === access.personId,
      sharedWith: this.o.platform.shares.of(MODULE, row.id).map(named),
      labels: labels.get(row.id) ?? [],
      startedAt: row.startedAt.toISOString(),
      durationSeconds: row.durationSeconds ?? null,
      status: row.status,
      error: row.error ?? null,
      source: row.source,
      audioBytes: row.audioBytes ?? null,
      hasTranscript: Boolean(row.transcript),
      hasSegments: Boolean(row.segments?.length),
      hasNotes: Boolean(row.notesMarkdown),
      markCount: row.marks.length,
      preview: preview?.slice(0, 200) ?? null,
      updatedAt: row.updatedAt.toISOString(),
    };
  }

  detail(row: RecordingRow, access: Access): RecordingDetail {
    return {
      ...this.summary(row, access),
      transcript: row.transcript ?? null,
      segments: row.segments ?? null,
      marks: row.marks,
      notes: typedNotes(row.notes),
      notesMarkdown: row.notesMarkdown ?? null,
    };
  }
}

function sortMarks(marks: Mark[]) {
  return [...marks].sort((a, b) => a.at - b.at);
}

// A dictation's title from its first words: "Hoi Ruben, de kozijnen aan…".
export function firstWords(text: string, max = 48) {
  const flat = text.replace(/\s+/g, ' ').trim();
  if (flat.length <= max) return flat;
  const cut = flat.slice(0, max);
  const space = cut.lastIndexOf(' ');
  return `${(space > 20 ? cut.slice(0, space) : cut).replace(/[,.;:]$/, '')}…`;
}

function result(summary: string, fields: Record<string, string> = {}) {
  return { summary, fields, ops: [], draft: null };
}
