import {
  type ClaimedTask,
  type ClaimRequest,
  type Queue,
  type QueueWork,
  type Runner,
  type Subject,
  type Task,
  type TaskPriority,
  type TaskResult,
  type TaskStatus,
  type TaskWhere,
  taskPriority,
  taskResult,
} from '@burrow/contracts';
import {
  and,
  count,
  desc,
  eq,
  inArray,
  isNull,
  lt,
  lte,
  ne,
  notInArray,
  or,
  sql,
} from 'drizzle-orm';
import type { Access } from '../access';
import type { AgentRequest, AgentRunner } from '../agents/runner';
import type { Db } from '../db';
import type { EventBus } from '../events';
import { people, runners, tasks } from '../schema';
import type { Subjects } from './subjects';

export type TaskRow = typeof tasks.$inferSelect;
export type RunnerRow = typeof runners.$inferSelect;

// Work a module hands out piece by piece instead of as one task row per item
// (indexing fifty thousand messages): on each claim it gives the next piece
// of what is still missing. The task row lives only while a runner holds the
// piece; a runner that stops loses nothing.
export type StandingWork = {
  // People who have work of this kind waiting.
  people: () => string[];
  progress: (personId: string) => { waiting: number; done: number | null };
  // The next piece for the person, skipping what the running tasks hold. A
  // runner's key may see only part of the person's things (some mailboxes);
  // the server's pool has no key.
  next: (
    personId: string,
    running: TaskRow[],
    access?: Access,
  ) =>
    | { subject?: Subject | null; input?: Record<string, unknown> }
    | undefined;
};

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
  // What the queue view calls this work, e.g. "Mail-facts".
  title?: string;
  queue?: Queue;
  priority?: TaskPriority;
  // A model every task of this kind must run on (haiku, ollama:<name>).
  model?: string;
  standing?: StandingWork;
};

export type NewTask = {
  kind: string;
  personId: string;
  subject?: Subject | null;
  input?: Record<string, unknown>;
  where?: TaskWhere;
  routineId?: string | null;
  fallbackAt?: Date | null;
  priority?: TaskPriority;
  model?: string | null;
};

// A client that claimed a task and went quiet gives it back after this.
const CLAIM_TIMEOUT_MS = 30 * 60_000;
// A runner silent for longer shows as offline.
const ONLINE_MS = 5 * 60_000;
const SERVER = 'server';
const CLOUD_MODELS = new Set(['haiku', 'opus']);

const rank = (p: TaskPriority) => taskPriority.options.indexOf(p);

export class WorkerError extends Error {}

export type WorkersOptions = {
  db: Db;
  events: EventBus;
  subjects: Subjects;
  runner: AgentRunner;
  // Server tasks running at once.
  concurrency: number;
  // The agent CLIs of the server's own pool.
  agents?: string[];
  // Whether a person lets the household's other Macs run their cloud work.
  sharesCloudWork?: (personId: string) => boolean;
};

// The task queue and the server's worker pool. Every runner (a Mac, the
// server's pool) claims the highest-priority task it may run: local tasks
// only on a device of their person with a local model, cloud tasks on any
// cloud agent that works for their person.
export class Workers {
  private readonly kinds = new Map<string, TaskKind>();
  private readonly running = new Set<Promise<void>>();
  private readonly db: Db;
  private serverId?: string;

  constructor(private readonly o: WorkersOptions) {
    this.db = o.db;
  }

  register(kind: TaskKind) {
    if (this.kinds.has(kind.name)) {
      throw new WorkerError(`task kind "${kind.name}" is registered twice`);
    }
    if (!kind.agent === !kind.run) {
      throw new WorkerError(`task kind "${kind.name}" needs agent or run`);
    }
    if (kind.queue === 'local' && !kind.agent) {
      throw new WorkerError(`local task kind "${kind.name}" needs an agent`);
    }
    this.kinds.set(kind.name, kind);
  }

  enqueue(t: NewTask): string {
    const kind = this.kinds.get(t.kind);
    if (!kind) {
      throw new WorkerError(`unknown task kind "${t.kind}"`);
    }
    if (kind.standing) {
      throw new WorkerError(`task kind "${t.kind}" is standing work`);
    }
    const row = this.db
      .insert(tasks)
      .values({
        kind: t.kind,
        personId: t.personId,
        routineId: t.routineId ?? null,
        subjectType: t.subject?.type ?? null,
        subjectId: t.subject?.id ?? null,
        input: t.input ?? null,
        where: t.where ?? 'server',
        queue: kind.queue ?? 'cloud',
        priority: rank(t.priority ?? kind.priority ?? 'normal'),
        model: t.model ?? kind.model ?? null,
        fallbackAt: t.fallbackAt ?? null,
        status: 'queued',
      })
      .returning()
      .get();
    this.changed(row);
    this.pump();
    return row.id;
  }

  // Starts server tasks while there is room in the pool.
  pump() {
    const server = this.serverRunner();
    if (server.paused) return;
    while (this.running.size < this.o.concurrency) {
      const next = this.next(server);
      if (!next) return;
      const run: Promise<void> = this.execute(next).finally(() => {
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
    for (const row of this.db
      .select()
      .from(tasks)
      .where(
        and(
          eq(tasks.status, 'running'),
          eq(tasks.runnerId, this.serverRunner().id),
        ),
      )
      .all()) {
      this.release(row, false);
    }
    this.pump();
  }

  // Every minute: hands stalled client claims back to the queue and moves
  // client tasks past their fallback moment to the server.
  tick(now = new Date()) {
    for (const row of this.db
      .select()
      .from(tasks)
      .where(
        and(
          eq(tasks.status, 'running'),
          or(
            isNull(tasks.runnerId),
            ne(tasks.runnerId, this.serverRunner().id),
          ),
          lt(tasks.claimedAt, new Date(now.getTime() - CLAIM_TIMEOUT_MS)),
        ),
      )
      .all()) {
      this.release(row, true);
    }
    this.db
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
    this.db
      .update(runners)
      .set({ lastSeenAt: now })
      .where(eq(runners.id, this.serverRunner().id))
      .run();
    this.pump();
  }

  // A claim nobody finishes goes back. Standing work is handed out again, and
  // a piece that timed out counts as an attempt, so one that hangs every
  // runner is given up in the end.
  private release(row: TaskRow, timedOut: boolean) {
    if (this.isStanding(row)) {
      if (timedOut) this.giveUp(row, 'the runner never answered');
      else this.finish(row);
      return;
    }
    this.setStatus(row.id, 'queued', {
      claimedBy: null,
      claimedAt: null,
      runnerId: null,
    });
  }

  // --- choosing work ------------------------------------------------------

  // The best task the runner may run now, claimed for it.
  private next(r: RunnerRow, access?: Access): TaskRow | undefined {
    let regular: TaskRow | undefined;
    for (const row of this.db
      .select()
      .from(tasks)
      .where(eq(tasks.status, 'queued'))
      .orderBy(desc(tasks.priority), tasks.createdAt, sql`rowid`)
      .limit(200)
      .all()) {
      if (this.fits(row, r, access)) {
        regular = row;
        break;
      }
    }
    const floor = regular ? regular.priority : -1;
    for (const kind of this.standingFor(r)) {
      if (rank(kind.priority ?? 'low') <= floor) break;
      const piece = this.standingPiece(kind, r, access);
      if (piece) return piece;
    }
    return regular && this.claimRow(regular, r);
  }

  private fits(t: TaskRow, r: RunnerRow, access?: Access): boolean {
    const kind = this.kinds.get(t.kind);
    if (!kind || kind.standing) return false;
    if (this.isServer(r)) {
      return (
        t.queue === 'cloud' &&
        t.where === 'server' &&
        !t.model?.startsWith('ollama:')
      );
    }
    if (!kind.agent) return false;
    if (!r.kinds.includes('*') && !r.kinds.includes(t.kind)) return false;
    const own = t.personId === r.personId;
    if (own && access && !this.visible(t, access)) return false;
    if (t.queue === 'local') {
      return own && Boolean(this.localModel(r, t.model));
    }
    if (!own && !this.o.sharesCloudWork?.(t.personId)) return false;
    return t.where === 'client' && this.cloudModel(r, t.model);
  }

  private localModel(r: RunnerRow, pinned: string | null | undefined) {
    if (!r.queues.includes('local')) return undefined;
    return pinned ? r.models.find((m) => m === pinned) : r.models[0];
  }

  private cloudModel(r: RunnerRow, pinned: string | null | undefined) {
    if (!r.queues.includes('cloud') || !r.agents.length) return false;
    return !pinned || (CLOUD_MODELS.has(pinned) && r.agents.includes('claude'));
  }

  // Standing kinds the runner can serve, highest priority first.
  private standingFor(r: RunnerRow): TaskKind[] {
    return [...this.kinds.values()]
      .filter((k) => {
        if (!k.standing) return false;
        const queue = k.queue ?? 'cloud';
        if (this.isServer(r)) return queue === 'cloud';
        if (!k.agent) return false;
        if (!r.kinds.includes('*') && !r.kinds.includes(k.name)) return false;
        return queue === 'local'
          ? Boolean(this.localModel(r, k.model))
          : this.cloudModel(r, k.model);
      })
      .sort((a, b) => rank(b.priority ?? 'low') - rank(a.priority ?? 'low'));
  }

  private standingPiece(
    kind: TaskKind,
    r: RunnerRow,
    access?: Access,
  ): TaskRow | undefined {
    const work = kind.standing!;
    const candidates = r.personId ? [r.personId] : work.people();
    for (const personId of candidates) {
      const running = this.db
        .select()
        .from(tasks)
        .where(
          and(
            eq(tasks.kind, kind.name),
            eq(tasks.personId, personId),
            eq(tasks.status, 'running'),
          ),
        )
        .all();
      const piece = work.next(personId, running, access);
      if (!piece) continue;
      return this.db
        .insert(tasks)
        .values({
          kind: kind.name,
          personId,
          subjectType: piece.subject?.type ?? null,
          subjectId: piece.subject?.id ?? null,
          input: piece.input ?? null,
          where: this.isServer(r) ? 'server' : 'client',
          queue: kind.queue ?? 'cloud',
          priority: rank(kind.priority ?? 'low'),
          model: this.modelFor(kind.queue ?? 'cloud', kind.model, r),
          status: 'running',
          claimedBy: r.name,
          claimedAt: new Date(),
          runnerId: r.id,
          attempts: 1,
        })
        .returning()
        .get();
    }
    return undefined;
  }

  private claimRow(t: TaskRow, r: RunnerRow): TaskRow {
    return this.setStatus(t.id, 'running', {
      claimedBy: r.name,
      claimedAt: new Date(),
      runnerId: r.id,
      attempts: t.attempts + 1,
      model: this.modelFor(t.queue, t.model, r),
    });
  }

  // A local task always runs on a local model of the runner that holds it.
  private modelFor(
    queue: Queue,
    pinned: string | null | undefined,
    r: RunnerRow,
  ) {
    return queue === 'local'
      ? (this.localModel(r, pinned) ?? null)
      : (pinned ?? null);
  }

  // The kind builds the request; the task's model wins over the bot's own,
  // and a local task never reaches a cloud agent.
  private request(row: TaskRow): AgentRequest {
    const request = this.kinds.get(row.kind)!.agent!.request(row);
    const model = row.model ? { ...request, model: row.model } : request;
    return row.queue === 'local'
      ? { ...model, agent: 'local', effort: undefined }
      : model;
  }

  // --- running ------------------------------------------------------------

  private async execute(row: TaskRow) {
    const kind = this.kinds.get(row.kind);
    if (!kind) {
      this.giveUp(row, `unknown task kind "${row.kind}"`);
      return;
    }
    try {
      const result = kind.run
        ? await kind.run(row)
        : this.accept(kind, row, await this.o.runner.run(this.request(row)));
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
      if (kind?.standing) this.finish(row);
      else this.setStatus(row.id, 'done');
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
    if (this.isStanding(row)) this.finish(row);
  }

  // A standing row only lives while a runner holds the piece.
  private finish(row: TaskRow) {
    this.db.delete(tasks).where(eq(tasks.id, row.id)).run();
  }

  // --- people and clients -------------------------------------------------

  list(
    access: Access,
    filter: { limit?: number; kinds?: string[]; subject?: Subject } = {},
  ): Task[] {
    const standing = this.standingNames;
    return (
      this.db
        .select()
        .from(tasks)
        .where(
          and(
            eq(tasks.personId, access.personId),
            filter.kinds?.length
              ? inArray(tasks.kind, filter.kinds)
              : undefined,
            standing.length ? notInArray(tasks.kind, standing) : undefined,
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
      runnerId: null,
    });
    this.pump();
  }

  // Registers the runner (each claim is its heartbeat) and hands it the best
  // tasks it may run, with the agent request already built.
  claim(access: Access, offer: ClaimRequest): ClaimedTask[] {
    // Task prompts carry content, which a facts-only key never reads.
    if (access.factsOnly) throw new WorkerError('this key reads facts only');
    const r = this.registerRunner(access, offer);
    if (r.paused) return [];
    const claimed: ClaimedTask[] = [];
    while (claimed.length < offer.max) {
      const next = this.next(r, access);
      if (!next) break;
      let request: AgentRequest;
      try {
        request = this.request(next);
      } catch (error) {
        this.giveUp(next, (error as Error).message);
        continue;
      }
      claimed.push({
        task: this.toTask(next),
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
    const row = this.claimedBy(id, access);
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
    this.giveUp(this.claimedBy(id, access), error);
  }

  // --- runners ------------------------------------------------------------

  private registerRunner(access: Access, offer: ClaimRequest): RunnerRow {
    const values = {
      personId: access.personId,
      // The local queue needs a local model on the same device.
      queues: offer.models.length
        ? offer.queues
        : offer.queues.filter((q) => q !== 'local'),
      agents: offer.agents,
      models: offer.models,
      kinds: offer.kinds,
      concurrency: offer.concurrency,
      lastSeenAt: new Date(),
    };
    return this.db
      .insert(runners)
      .values({ keyId: access.keyId, name: offer.runner, ...values })
      .onConflictDoUpdate({
        target: [runners.keyId, runners.name],
        set: values,
      })
      .returning()
      .get();
  }

  // The server's own pool, registered like any other runner but without a
  // key; known by its id, since a Mac may call itself "server" too.
  serverRunner(): RunnerRow {
    const found = this.db
      .select()
      .from(runners)
      .where(and(isNull(runners.keyId), eq(runners.name, SERVER)))
      .get();
    if (found) {
      this.serverId = found.id;
      return found;
    }
    const created = this.db
      .insert(runners)
      .values({
        keyId: null,
        personId: null,
        name: SERVER,
        queues: ['cloud'],
        agents: this.o.agents ?? ['claude'],
        models: [],
        kinds: ['*'],
        concurrency: this.o.concurrency,
        lastSeenAt: new Date(),
      })
      .returning()
      .get();
    this.serverId = created.id;
    return created;
  }

  private isServer(r: RunnerRow) {
    return (
      r.keyId === null && r.id === (this.serverId ?? this.serverRunner().id)
    );
  }

  runners(access: Access, now = new Date()): Runner[] {
    this.serverRunner();
    return this.db
      .select({ runner: runners, personName: people.name })
      .from(runners)
      .leftJoin(people, eq(people.id, runners.personId))
      .orderBy(sql`${runners.keyId} is not null`, runners.createdAt)
      .all()
      .map(({ runner: r, personName }) => {
        const mine = r.personId === access.personId;
        const doing = mine
          ? this.db
              .select()
              .from(tasks)
              .where(and(eq(tasks.runnerId, r.id), eq(tasks.status, 'running')))
              .all()
              .map((t) => this.toTask(t).title)
          : [];
        return {
          id: r.id,
          name: r.name,
          personName: personName ?? null,
          mine,
          queues: r.queues,
          agents: r.agents,
          models: r.models,
          kinds: r.kinds,
          paused: r.paused,
          online:
            r.keyId === null ||
            (r.lastSeenAt !== null &&
              now.getTime() - r.lastSeenAt.getTime() < ONLINE_MS),
          lastSeenAt: r.lastSeenAt?.toISOString() ?? null,
          doing: doing.length ? [...new Set(doing)].join(', ') : null,
        };
      });
  }

  // A person pauses their own runners; the server's pool only an admin.
  setPaused(id: string, access: Access, paused: boolean): Runner {
    const r = this.ownRunner(id, access, true);
    this.db.update(runners).set({ paused }).where(eq(runners.id, r.id)).run();
    if (!paused && r.keyId === null) this.pump();
    return this.runners(access).find((x) => x.id === id)!;
  }

  removeRunner(id: string, access: Access) {
    const r = this.ownRunner(id, access, false);
    this.db
      .update(tasks)
      .set({ runnerId: null })
      .where(eq(tasks.runnerId, r.id))
      .run();
    this.db.delete(runners).where(eq(runners.id, r.id)).run();
  }

  private ownRunner(id: string, access: Access, serverToo: boolean) {
    const r = this.db.select().from(runners).where(eq(runners.id, id)).get();
    const allowed =
      r &&
      ((r.keyId !== null && r.personId === access.personId) ||
        (serverToo && r.keyId === null && access.rights.has('admin')));
    if (!allowed) throw new WorkerError('not found');
    return r;
  }

  // What waits for the key's person, per kind; standing work with progress.
  work(access: Access): QueueWork[] {
    const waiting = this.db
      .select({ queue: tasks.queue, kind: tasks.kind, n: count() })
      .from(tasks)
      .where(
        and(eq(tasks.personId, access.personId), eq(tasks.status, 'queued')),
      )
      .groupBy(tasks.queue, tasks.kind)
      .all()
      .map(({ queue, kind, n }) => ({
        queue,
        kind,
        title: this.kinds.get(kind)?.title ?? kind,
        waiting: n,
        done: null,
      }));
    const standing = [...this.kinds.values()]
      .filter((k) => k.standing)
      .map((k) => ({
        queue: k.queue ?? 'cloud',
        kind: k.name,
        title: k.title ?? k.name,
        ...k.standing!.progress(access.personId),
      }))
      .filter((w) => w.waiting > 0 || w.done !== null);
    return [...waiting, ...standing];
  }

  // --- helpers ------------------------------------------------------------

  task(id: string): TaskRow | undefined {
    return this.db.select().from(tasks).where(eq(tasks.id, id)).get();
  }

  private get standingNames() {
    return [...this.kinds.values()]
      .filter((k) => k.standing)
      .map((k) => k.name);
  }

  private isStanding(row: TaskRow) {
    return Boolean(this.kinds.get(row.kind)?.standing);
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

  // A running task is finished by the key whose runner claimed it.
  private claimedBy(id: string, access: Access): TaskRow {
    const t = this.task(id);
    if (!t || t.status !== 'running' || t.runnerId === this.serverRunner().id) {
      throw new WorkerError('not found');
    }
    const r = t.runnerId
      ? this.db.select().from(runners).where(eq(runners.id, t.runnerId)).get()
      : undefined;
    if (r ? r.keyId !== access.keyId : !this.visible(t, access)) {
      throw new WorkerError('not found');
    }
    return t;
  }

  private setStatus(
    id: string,
    status: TaskStatus,
    extra: Partial<TaskRow> = {},
  ): TaskRow {
    const row = this.db
      .update(tasks)
      .set({ ...extra, status, updatedAt: new Date() })
      .where(eq(tasks.id, id))
      .returning()
      .get()!;
    this.changed(row);
    return row;
  }

  private changed(row: TaskRow) {
    if (this.isStanding(row)) return;
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
      queue: t.queue,
      priority: taskPriority.options[t.priority] ?? 'normal',
      model: t.model ?? null,
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
