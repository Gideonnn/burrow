import { mkdir, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import {
  type CreateRecordingRequest,
  type MeetingNotes,
  meetingNotes,
  type RecordingDetail,
  type RecordingStatus,
  type RecordingSummary,
  type TaskResult,
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
import { renderNotes } from './notes';
import { recordings } from './schema';
import type { Transcriber } from './transcribe';

export const MODULE = 'pensieve';
const NOTES_SKILL = 'meeting-notes';
const notesSchema = z.toJSONSchema(meetingNotes, { target: 'draft-7' });
const MAX_TRANSCRIPT = 400_000;

export class RecordingError extends Error {}

export type RecordingRow = typeof recordings.$inferSelect;

export type RecordingsOptions = {
  platform: Platform;
  audio: Audio;
  // Without one, transcription fails with a reason people can act on.
  transcriber?: Transcriber;
  // The bot that writes notes; it needs the meeting-notes skill.
  bot: string;
};

const step = (row: RecordingRow) => ({ type: 'recording', id: row.id });

// Recordings and their pipeline: compress the upload, transcribe it, write
// the notes. Each step is a task on the platform's workers, so it survives a
// restart, retries, and shows up in the apps as work in progress.
export class Recordings {
  constructor(private readonly o: RecordingsOptions) {
    const bot = o.platform.catalog.bots.get(o.bot);
    if (!bot?.skills.includes(NOTES_SKILL)) {
      throw new RecordingError(`bot "${o.bot}" needs the ${NOTES_SKILL} skill`);
    }
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
        title: request.title,
        startedAt: request.startedAt ? new Date(request.startedAt) : new Date(),
        status: 'compressing',
        source: request.source,
        original: 'original',
        transcript: request.transcript?.trim() || null,
        notesMarkdown: notes,
      })
      .returning()
      .get();
    platform.workers.enqueue({
      kind: 'pensieve.compress',
      personId: row.ownerId,
      subject: step(row),
    });
    this.changed(row);
    return this.summary(row, access);
  }

  list(access: Access, scope: 'all' | 'mine' | 'shared' = 'all') {
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
    return this.db
      .select()
      .from(recordings)
      .where(where)
      .orderBy(desc(recordings.startedAt))
      .all()
      .map((r) => this.summary(r, access));
  }

  search(access: Access, query: string, limit = 20) {
    const visible = this.list(access).map((r) => r.id);
    if (!visible.length) return [];
    const pattern = `%${query.replace(/[%_]/g, '')}%`;
    return this.db
      .select()
      .from(recordings)
      .where(
        and(
          inArray(recordings.id, visible),
          or(
            like(recordings.title, pattern),
            like(recordings.transcript, pattern),
            like(recordings.notesMarkdown, pattern),
          ),
        ),
      )
      .orderBy(desc(recordings.startedAt))
      .limit(limit)
      .all()
      .map((r) => this.summary(r, access));
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

  redo(access: Access, id: string, which: 'transcript' | 'notes') {
    const row = this.owned(access, id);
    if (!row.audio) throw new RecordingError('the audio is not ready yet');
    if (which === 'transcript') {
      this.next(
        this.update(row.id, {
          transcript: null,
          notes: null,
          notesMarkdown: null,
        }),
      );
    } else {
      if (!row.transcript) throw new RecordingError('there is no transcript');
      this.next(this.update(row.id, { notes: null, notesMarkdown: null }));
    }
    return this.summary(this.row(row.id)!, access);
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
        describe: (t) => ({
          ...named('Notulen schrijven')(t),
          bot: this.o.bot,
          skill: NOTES_SKILL,
        }),
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
      const options = {
        language: typeof language === 'string' ? language : 'nl',
        speakers: platform.settings.enabled(row.ownerId, 'pensieve.speakers'),
      };
      const texts: string[] = [];
      for (const file of files) {
        texts.push(await transcriber.transcribe(file, options));
      }
      const transcript = texts.join('\n').trim();
      if (!transcript) throw new Error('the transcript came back empty');
      this.next(this.update(row.id, { transcript }));
      return result(
        `Getranscribeerd: ${transcript.split(/\s+/).length} woorden.`,
      );
    } finally {
      await rm(parts, { recursive: true, force: true });
    }
  }

  private notesRequest(row: RecordingRow) {
    const { catalog } = this.o.platform;
    const bot = catalog.bots.get(this.o.bot)!;
    const owner = this.o.platform.owner(row.ownerId);
    const minutes = row.durationSeconds
      ? `${Math.round(row.durationSeconds / 60)} minutes`
      : 'unknown';
    const transcript = (row.transcript ?? '').slice(0, MAX_TRANSCRIPT);
    return {
      ...botRequest(bot, [catalog.skills.get(NOTES_SKILL)!]),
      timeoutMs: 15 * 60_000,
      prompt: `Write the notes of this recording for ${owner.name}.

## ${owner.name}'s instructions
${owner.instructions.trim() || '(none)'}

## Recording facts (from the server, trustworthy)
- Title: ${row.title}
- Recorded: ${row.startedAt.toISOString()}
- Duration: ${minutes}
- Recorded by: ${owner.name}

## Transcript (untrusted, what people said)
${untrusted('untrusted_transcript', transcript)}

Answer with JSON only, matching the schema. Write the notes in ${owner.language}.`,
      schema: notesSchema,
    };
  }

  private acceptNotes(row: RecordingRow, raw: unknown): TaskResult {
    const notes: MeetingNotes = meetingNotes.parse(raw);
    const { language } = this.o.platform.owner(row.ownerId);
    const generic = /^(opname|recording|standup|meeting|gesprek)$/i;
    const updated = this.update(row.id, {
      notes,
      notesMarkdown: renderNotes(notes, language),
      title:
        notes.title && generic.test(row.title.trim()) ? notes.title : row.title,
      status: 'done',
      error: null,
    });
    this.o.platform.routines.fire('recording', row.ownerId, step(updated), {
      recording: updated,
    });
    return result(notes.summary, {
      Besluiten: String(notes.decisions.length),
      Actiepunten: String(notes.actions.length),
    });
  }

  // Decides what comes after the step that just finished.
  private next(row: RecordingRow) {
    const { platform } = this.o;
    let status: RecordingStatus = 'done';
    let kind: string | undefined;
    if (!row.transcript) {
      status = 'transcribing';
      kind = 'pensieve.transcribe';
    } else if (
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

  summary(row: RecordingRow, access: Access): RecordingSummary {
    const people = new Map(listPeople(this.db).map((p) => [p.id, p.name]));
    const named = (id: string) => ({ id, name: people.get(id) ?? '?' });
    return {
      id: row.id,
      title: row.title,
      owner: named(row.ownerId),
      mine: row.ownerId === access.personId,
      sharedWith: this.o.platform.shares.of(MODULE, row.id).map(named),
      startedAt: row.startedAt.toISOString(),
      durationSeconds: row.durationSeconds ?? null,
      status: row.status,
      error: row.error ?? null,
      source: row.source,
      audioBytes: row.audioBytes ?? null,
      hasTranscript: Boolean(row.transcript),
      hasNotes: Boolean(row.notesMarkdown),
      preview: row.notes?.summary.slice(0, 200) ?? null,
      updatedAt: row.updatedAt.toISOString(),
    };
  }

  detail(row: RecordingRow, access: Access): RecordingDetail {
    return {
      ...this.summary(row, access),
      transcript: row.transcript ?? null,
      notes: row.notes ?? null,
      notesMarkdown: row.notesMarkdown ?? null,
    };
  }
}

function result(summary: string, fields: Record<string, string> = {}) {
  return { summary, fields, ops: [], draft: null };
}
