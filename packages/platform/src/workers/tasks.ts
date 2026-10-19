import {
  type ClaimedTask,
  type Subject,
  type Task,
  type TaskResult,
  type TaskStatus,
  type TaskWhere,
  taskResult,
} from '@burrow/contracts';
import { and, desc, eq, inArray, lt, lte, ne, sql } from 'drizzle-orm';
import type { Access } from '../access';
import type { AgentRequest, AgentRunner } from '../agents/runner';
import type { Db } from '../db';
import type { EventBus } from '../events';
import { tasks } from '../schema';
import type { Subjects } from './subjects';

export type TaskRow = typeof tasks.$inferSelect;

// A kind of work a module offers. Agent kinds build a request for a bot and
// validate its answer, and may run on a client app; code kinds run code on the
// server (ffmpeg, a transcription API). Either way the result is a TaskResult:
// a summary people can read, plus fields.
export type TaskKind = {
  name: string;
  describe: (task: TaskRow) => {
    title: string;
    bot?: string;
    skill?: string;
    routineName?: string;
  };
  agent?: {
    request: (task: TaskRow) => AgentRequest;
    accept?: (task: TaskRow, raw: unknown) => TaskResult;
  };
  run?: (task: TaskRow) => Promise<TaskResult>;
  // True when a person approves the result before it is applied.
  review?: (task: TaskRow, result: TaskResult) => boolean;
  apply?: (task: TaskRow, result: TaskResult) => Promise<void>;
  // Called once a task gave up, so the module can show why.
  failed?: (task: TaskRow, error: string) => void;
  // Runs of a code kind before it fails for good (network hiccups).
  attempts?: number;
};

export type NewTask = {
  kind: string;
  personId: string;
  subject?: Subject | null;
  input?: Record<string, unknown>;
  where?: TaskWhere;
  routineId?: string | null;
  fallbackAt?: Date | null;
};

// A client that claimed a task and went quiet gives it back after this.
const CLAIM_TIMEOUT_MS = 30 * 60_000;

export class WorkerError extends Error {}

export type WorkersOptions = {
  db: Db;
  events: EventBus;
  subjects: Subjects;
  runner: AgentRunner;
  // Server tasks running at once.
  concurrency: number;
};

// The task queue and the server's worker pool. Client apps claim the kinds
// they can run while they are open.
export class Workers {
  private readonly kinds = new Map<string, TaskKind>();
  private readonly running = new Set<Promise<void>>();

  constructor(private readonly o: WorkersOptions) {}

  register(kind: TaskKind) {
    if (this.kinds.has(kind.name)) {
      throw new WorkerError(`task kind "${kind.name}" is registered twice`);
    }
    if (!kind.agent === !kind.run) {
      throw new WorkerError(`task kind "${kind.name}" needs agent or run`);
    }
    this.kinds.set(kind.name, kind);
  }

  enqueue(t: NewTask): string {
    if (!this.kinds.has(t.kind)) {
      throw new WorkerError(`unknown task kind "${t.kind}"`);
    }
    const row = this.o.db
      .insert(tasks)
      .values({
        kind: t.kind,
        personId: t.personId,
        routineId: t.routineId ?? null,
        subjectType: t.subject?.type ?? null,
        subjectId: t.subject?.id ?? null,
        input: t.input ?? null,
        where: t.where ?? 'server',
        fallbackAt: t.fallbackAt ?? null,
        status: 'queued',
      })
      .returning()
      .get();
    this.changed(row);
    this.pump();
    return row.id;
  }

  // Starts queued server tasks while there is room in the pool.
  pump() {
    while (this.running.size < this.o.concurrency) {
      const next = this.o.db
        .select()
        .from(tasks)
        .where(and(eq(tasks.status, 'queued'), eq(tasks.where, 'server')))
        .orderBy(tasks.createdAt)
        .limit(1)
        .get();
      if (!next) return;
      const claimed = this.setStatus(next.id, 'running', {
        claimedBy: 'server',
        claimedAt: new Date(),
        attempts: next.attempts + 1,
      });
      const run: Promise<void> = this.execute(claimed).finally(() => {
        this.running.delete(run);
        this.pump();
      });
      this.running.add(run);
    }
  }

  // Resolves once the pool is idle; for tests and shutdown.
  async drain() {
    while (this.running.size) await Promise.all(this.running);
  }

  // After a restart nothing runs on the server any more.
  recover() {
    this.o.db
      .update(tasks)
      .set({ status: 'queued', claimedBy: null, claimedAt: null })
      .where(and(eq(tasks.status, 'running'), eq(tasks.claimedBy, 'server')))
      .run();
    this.pump();
  }

  // Every minute: hands stalled client claims back to the queue and moves
  // client tasks past their fallback moment to the server.
  tick(now = new Date()) {
    this.o.db
      .update(tasks)
      .set({ status: 'queued', claimedBy: null, claimedAt: null })
      .where(
        and(
          eq(tasks.status, 'running'),
          ne(tasks.claimedBy, 'server'),
          lt(tasks.claimedAt, new Date(now.getTime() - CLAIM_TIMEOUT_MS)),
        ),
      )
      .run();
    this.o.db
      .update(tasks)
      .set({ where: 'server' })
      .where(
        and(
          eq(tasks.status, 'queued'),
          eq(tasks.where, 'client'),
          lte(tasks.fallbackAt, now),
        ),
      )
      .run();
    this.pump();
  }

  private async execute(row: TaskRow) {
    const kind = this.kinds.get(row.kind);
    if (!kind) {
      this.giveUp(row, `unknown task kind "${row.kind}"`);
      return;
    }
    try {
      const result = kind.run
        ? await kind.run(row)
        : this.accept(
            kind,
            row,
            await this.o.runner.run(kind.agent!.request(row)),
          );
      await this.settle(row.id, result);
    } catch (error) {
      const message = (error as Error).message;
      if (kind.run && row.attempts < (kind.attempts ?? 1)) {
        console.error(
          `task ${row.kind} ${row.id} failed, retrying: ${message}`,
        );
        this.setStatus(row.id, 'queued', { error: message, claimedBy: null });
      } else {
        this.giveUp(row, message);
      }
    }
  }

  private accept(kind: TaskKind, row: TaskRow, raw: unknown): TaskResult {
    return kind.agent?.accept
      ? kind.agent.accept(row, raw)
      : taskResult.parse(raw);
  }

  private async settle(id: string, result: TaskResult) {
    const row = this.setStatus(id, 'review', { result, error: null });
    if (this.kinds.get(row.kind)?.review?.(row, result)) return;
    await this.apply(row);
  }

  private async apply(row: TaskRow) {
    const kind = this.kinds.get(row.kind);
    try {
      await kind?.apply?.(row, row.result!);
      this.setStatus(row.id, 'done');
    } catch (error) {
      this.giveUp(row, (error as Error).message);
    }
  }

  private giveUp(row: TaskRow, error: string) {
    const failed = this.setStatus(row.id, 'failed', {
      error: error.slice(0, 1_000),
    });
    try {
      this.kinds.get(row.kind)?.failed?.(failed, error);
    } catch (hookError) {
      console.error(
        `failed hook of ${row.kind}: ${(hookError as Error).message}`,
      );
    }
  }

  // --- people and clients -------------------------------------------------

  list(
    access: Access,
    filter: { limit?: number; kinds?: string[]; subject?: Subject } = {},
  ): Task[] {
    return (
      this.o.db
        .select()
        .from(tasks)
        .where(
          and(
            eq(tasks.personId, access.personId),
            filter.kinds?.length
              ? inArray(tasks.kind, filter.kinds)
              : undefined,
            filter.subject
              ? eq(tasks.subjectType, filter.subject.type)
              : undefined,
            filter.subject ? eq(tasks.subjectId, filter.subject.id) : undefined,
          ),
        )
        // Tasks made in the same millisecond keep the order they were made in.
        .orderBy(desc(tasks.createdAt), desc(sql`rowid`))
        .limit(filter.limit ?? 100)
        .all()
        .filter((t) => this.visible(t, access))
        .map((t) => this.toTask(t))
    );
  }

  async approve(id: string, access: Access) {
    await this.apply(this.find(id, access, 'review'));
  }

  reject(id: string, access: Access) {
    this.setStatus(this.find(id, access, 'review').id, 'rejected');
  }

  retry(id: string, access: Access) {
    const row = this.find(id, access, 'failed');
    this.setStatus(row.id, 'queued', {
      error: null,
      attempts: 0,
      claimedBy: null,
      claimedAt: null,
    });
    this.pump();
  }

  // Hands queued client tasks of the key's person to a client runner.
  claim(
    access: Access,
    runnerName: string,
    kinds: string[],
    max = 2,
  ): ClaimedTask[] {
    const agentKinds = kinds.filter((k) => this.kinds.get(k)?.agent);
    if (!agentKinds.length) return [];
    const queued = this.o.db
      .select()
      .from(tasks)
      .where(
        and(
          eq(tasks.status, 'queued'),
          eq(tasks.where, 'client'),
          eq(tasks.personId, access.personId),
          inArray(tasks.kind, agentKinds),
        ),
      )
      .orderBy(tasks.createdAt)
      .all()
      .filter((t) => this.visible(t, access))
      .slice(0, max);
    const claimed: ClaimedTask[] = [];
    for (const t of queued) {
      let request: AgentRequest;
      try {
        request = this.kinds.get(t.kind)!.agent!.request(t);
      } catch (error) {
        this.giveUp(t, (error as Error).message);
        continue;
      }
      const row = this.setStatus(t.id, 'running', {
        claimedBy: runnerName,
        claimedAt: new Date(),
        attempts: t.attempts + 1,
      });
      claimed.push({
        task: this.toTask(row),
        request: {
          ...request,
          schema: request.schema as Record<string, unknown>,
          agent: request.agent ?? 'any',
        },
      });
    }
    return claimed;
  }

  async complete(id: string, access: Access, raw: unknown) {
    const row = this.find(id, access, 'running');
    if (row.claimedBy === 'server') throw new WorkerError('not found');
    let result: TaskResult;
    try {
      result = this.accept(this.kinds.get(row.kind)!, row, raw);
    } catch (error) {
      this.giveUp(row, `invalid result: ${(error as Error).message}`);
      throw new WorkerError('invalid result');
    }
    await this.settle(row.id, result);
  }

  fail(id: string, access: Access, error: string) {
    const row = this.find(id, access, 'running');
    if (row.claimedBy === 'server') throw new WorkerError('not found');
    this.giveUp(row, error);
  }

  // --- helpers ------------------------------------------------------------

  task(id: string): TaskRow | undefined {
    return this.o.db.select().from(tasks).where(eq(tasks.id, id)).get();
  }

  // A task is its person's; one about a subject is only visible to keys that
  // can see the subject (a key limited to some mailboxes).
  private visible(t: TaskRow, access: Access) {
    if (t.personId !== access.personId) return false;
    if (!t.subjectType || !t.subjectId) return true;
    return this.o.subjects.visible(access, {
      type: t.subjectType,
      id: t.subjectId,
    });
  }

  private find(id: string, access: Access, status: TaskStatus): TaskRow {
    const t = this.task(id);
    if (!t || !this.visible(t, access) || t.status !== status) {
      throw new WorkerError('not found');
    }
    return t;
  }

  private setStatus(
    id: string,
    status: TaskStatus,
    extra: Partial<TaskRow> = {},
  ): TaskRow {
    const row = this.o.db
      .update(tasks)
      .set({ ...extra, status, updatedAt: new Date() })
      .where(eq(tasks.id, id))
      .returning()
      .get()!;
    this.changed(row);
    return row;
  }

  private changed(row: TaskRow) {
    this.o.events.emitTo([row.personId], {
      type: 'task.changed',
      taskId: row.id,
      kind: row.kind,
      status: row.status,
    });
  }

  toTask(t: TaskRow): Task {
    const kind = this.kinds.get(t.kind);
    const about = kind?.describe(t) ?? { title: t.kind };
    const subject =
      t.subjectType && t.subjectId
        ? { type: t.subjectType, id: t.subjectId }
        : null;
    return {
      id: t.id,
      kind: t.kind,
      title: about.title,
      routineId: t.routineId ?? null,
      routineName: about.routineName ?? about.title,
      skill: about.skill ?? '',
      bot: about.bot ?? '',
      where: t.where,
      status: t.status,
      subject,
      messageId: subject?.type === 'message' ? subject.id : null,
      result: t.result ?? null,
      error: t.error ?? null,
      claimedBy: t.claimedBy ?? null,
      createdAt: t.createdAt.toISOString(),
      updatedAt: t.updatedAt.toISOString(),
    };
  }
}
