import {
  type ClaimedTask,
  type RoutineInput,
  type Task,
  type TaskResult,
  type TaskStatus,
  type TriageDecision,
  taskResult,
} from '@burrow/contracts';
import { and, desc, eq, inArray, lt } from 'drizzle-orm';
import { z } from 'zod';
import type { AgentRequest, AgentRunner } from '../agents/runner';
import type { Access } from '../auth/access';
import type { Catalog } from '../catalog/loadCatalog';
import type { Db } from '../db/client';
import { instructions, people, routines, tasks } from '../db/schema';
import { createDraft } from '../mail/drafts';
import type { MailService, MessageRow } from '../mail/service';
import { systemPrompt, triagePrompt } from '../triage/prompt';

const resultSchema = z.toJSONSchema(taskResult, { target: 'draft-7' });
// A client that claimed a task and went quiet gives it back after this.
const CLAIM_TIMEOUT_MS = 30 * 60_000;

export class RoutineError extends Error {}

type RoutineRow = typeof routines.$inferSelect;
type TaskRow = typeof tasks.$inferSelect;

export type RoutineOptions = {
  db: Db;
  mail: MailService;
  runner: AgentRunner;
  catalog: Catalog;
  language?: string;
};

// Routines turn triggers into tasks; tasks run a bot with one skill, on the
// server or on a client app, and return a proposal (summary, fields, provider
// operations, a draft) that is applied after approval.
export class RoutineService {
  private queue: Promise<void> = Promise.resolve();

  constructor(private readonly o: RoutineOptions) {}

  // --- routines -----------------------------------------------------------

  list(personId: string) {
    return this.o.db
      .select()
      .from(routines)
      .where(eq(routines.personId, personId))
      .orderBy(routines.createdAt)
      .all()
      .map(toRoutine);
  }

  create(personId: string, input: RoutineInput) {
    this.validate(input);
    return toRoutine(
      this.o.db
        .insert(routines)
        .values({ personId, ...input })
        .returning()
        .get(),
    );
  }

  update(personId: string, id: string, input: RoutineInput) {
    this.validate(input);
    const row = this.o.db
      .update(routines)
      .set(input)
      .where(and(eq(routines.id, id), eq(routines.personId, personId)))
      .returning()
      .get();
    if (!row) throw new RoutineError('not found');
    return toRoutine(row);
  }

  remove(personId: string, id: string): boolean {
    return (
      this.o.db
        .delete(routines)
        .where(and(eq(routines.id, id), eq(routines.personId, personId)))
        .returning()
        .all().length > 0
    );
  }

  private validate(input: RoutineInput) {
    const bot = this.o.catalog.bots.get(input.bot);
    if (!bot) throw new RoutineError(`unknown bot "${input.bot}"`);
    if (!this.o.catalog.skills.has(input.skill))
      throw new RoutineError(`unknown skill "${input.skill}"`);
    if (!bot.skills.includes(input.skill)) {
      throw new RoutineError(
        `bot "${input.bot}" may not use the skill "${input.skill}"`,
      );
    }
    if (input.where === 'server' && input.fallbackAfterHours !== null) {
      throw new RoutineError('a fallback only applies to client routines');
    }
  }

  // --- triggers -----------------------------------------------------------

  // Called after triage: starts every matching message routine of the owner.
  onTriaged(messageId: string, decision: TriageDecision) {
    const message = this.o.mail.message(messageId);
    if (!message) return;
    const owner = this.o.mail.mailbox(message.mailboxId)!.ownerId;
    for (const r of this.enabled(owner)) {
      if (r.trigger.kind === 'message' && matches(r.trigger, message, decision))
        this.start(r, message.id);
    }
  }

  // Called every minute; starts schedule routines that are due, and hands
  // stalled or long-waiting client tasks to the server.
  tick(now = new Date()) {
    for (const r of this.o.db
      .select()
      .from(routines)
      .where(eq(routines.enabled, true))
      .all()) {
      if (r.trigger.kind !== 'schedule') continue;
      const due =
        !r.lastRunAt ||
        now.getTime() - r.lastRunAt.getTime() >=
          r.trigger.everyMinutes * 60_000;
      if (!due) continue;
      this.o.db
        .update(routines)
        .set({ lastRunAt: now })
        .where(eq(routines.id, r.id))
        .run();
      this.start(r, null);
    }
    this.o.db
      .update(tasks)
      .set({
        status: 'queued',
        claimedBy: null,
        claimedAt: null,
        updatedAt: now,
      })
      .where(
        and(
          eq(tasks.status, 'running'),
          lt(tasks.claimedAt, new Date(now.getTime() - CLAIM_TIMEOUT_MS)),
        ),
      )
      .run();
    for (const t of this.o.db
      .select()
      .from(tasks)
      .where(eq(tasks.status, 'queued'))
      .all()) {
      const r = this.routine(t.routineId);
      if (r?.where !== 'client' || r.fallbackAfterHours === null) continue;
      if (
        now.getTime() - t.createdAt.getTime() >=
        r.fallbackAfterHours * 3_600_000
      )
        this.runOnServer(t.id);
    }
  }

  private enabled(personId: string) {
    return this.o.db
      .select()
      .from(routines)
      .where(and(eq(routines.personId, personId), eq(routines.enabled, true)))
      .all();
  }

  private start(r: RoutineRow, messageId: string | null): string {
    const row = this.o.db
      .insert(tasks)
      .values({
        routineId: r.id,
        personId: r.personId,
        messageId,
        status: 'queued',
      })
      .returning()
      .get();
    if (r.where === 'server') this.runOnServer(row.id);
    return row.id;
  }

  // --- running ------------------------------------------------------------

  runOnServer(taskId: string): Promise<void> {
    this.queue = this.queue.then(async () => {
      const t = this.task(taskId);
      if (!t || t.status !== 'queued') return;
      this.setStatus(t.id, 'running', {
        claimedBy: 'server',
        claimedAt: new Date(),
      });
      try {
        this.accept(t.id, await this.o.runner.run(this.request(t)));
      } catch (error) {
        this.setStatus(t.id, 'failed', { error: (error as Error).message });
      }
    });
    return this.queue;
  }

  // The prompt is built here, also for client runners, so a client never needs
  // the bots, skills or the owner's instructions itself.
  request(t: TaskRow): AgentRequest {
    const r = this.routine(t.routineId)!;
    const { db, catalog, mail } = this.o;
    const bot = catalog.bots.get(r.bot)!;
    const owner = db
      .select()
      .from(people)
      .where(eq(people.id, t.personId))
      .get()!;
    const ownerInstructions =
      db
        .select()
        .from(instructions)
        .where(eq(instructions.personId, owner.id))
        .get()?.text ?? '';
    const message = t.messageId ? mail.message(t.messageId) : undefined;
    const language = this.o.language ?? 'English';
    const prompt = message
      ? triagePrompt({
          ownerName: owner.name,
          instructions: ownerInstructions,
          rules: [],
          mailbox: (({ address, provider }) => ({ address, provider }))(
            mail.mailbox(message.mailboxId)!,
          ),
          message,
          ownerWroteToSender: false,
          language,
          task: `Run the routine "${r.name}" for`,
        })
      : `Run the routine "${r.name}" for ${owner.name} on ${new Date().toISOString().slice(0, 10)}.\n\n## ${owner.name}'s instructions\n${ownerInstructions || '(none)'}\n\nAnswer with JSON only, matching the schema. Write any text for people in ${language}.`;
    return {
      model: bot.model,
      system: systemPrompt(bot, [catalog.skills.get(r.skill)!]),
      prompt,
      schema: resultSchema,
    };
  }

  // Validates a raw agent answer and either waits for approval or applies it.
  private accept(taskId: string, raw: unknown) {
    const result = taskResult.parse(raw);
    const t = this.task(taskId)!;
    const r = this.routine(t.routineId)!;
    this.setStatus(t.id, 'review', { result, error: null });
    if (!r.approval) void this.apply(t.id);
  }

  private async apply(taskId: string) {
    const t = this.task(taskId)!;
    const r = this.routine(t.routineId)!;
    const result = t.result!;
    const message = t.messageId ? this.o.mail.message(t.messageId) : undefined;
    try {
      if (result.ops.length && message)
        await this.o.mail.apply(message.id, result.ops);
      if (result.draft && message) {
        createDraft(
          this.o.db,
          {
            keyId: 'routine',
            keyName: r.name,
            personId: t.personId,
            rights: new Set(['draft']),
            mailboxIds: [message.mailboxId],
          },
          {
            mailboxId: message.mailboxId,
            cc: [],
            inReplyTo: message.id,
            ...result.draft,
          },
        );
      }
      this.setStatus(t.id, 'done');
    } catch (error) {
      this.setStatus(t.id, 'failed', { error: (error as Error).message });
    }
  }

  // --- people and clients -------------------------------------------------

  listTasks(access: Access, limit = 100): Task[] {
    return this.o.db
      .select()
      .from(tasks)
      .where(eq(tasks.personId, access.personId))
      .orderBy(desc(tasks.createdAt))
      .limit(limit)
      .all()
      .filter((t) => this.visible(t, access))
      .map((t) => this.toTask(t));
  }

  async approve(taskId: string, access: Access) {
    const t = this.reviewable(taskId, access);
    await this.apply(t.id);
  }

  reject(taskId: string, access: Access) {
    const t = this.reviewable(taskId, access);
    this.setStatus(t.id, 'rejected');
  }

  // Hands queued client tasks of the key's person to a client runner.
  claim(access: Access, runnerName: string, max = 2): ClaimedTask[] {
    const clientRoutines = this.o.db
      .select({ id: routines.id })
      .from(routines)
      .where(
        and(
          eq(routines.personId, access.personId),
          eq(routines.where, 'client'),
        ),
      )
      .all()
      .map((r) => r.id);
    if (!clientRoutines.length) return [];
    const queued = this.o.db
      .select()
      .from(tasks)
      .where(
        and(
          eq(tasks.status, 'queued'),
          inArray(tasks.routineId, clientRoutines),
        ),
      )
      .orderBy(tasks.createdAt)
      .all()
      .filter((t) => this.visible(t, access))
      .slice(0, max);
    return queued.map((t) => {
      this.setStatus(t.id, 'running', {
        claimedBy: runnerName,
        claimedAt: new Date(),
      });
      return {
        task: this.toTask(this.task(t.id)!),
        request: this.request(t) as ClaimedTask['request'],
      };
    });
  }

  complete(taskId: string, access: Access, raw: unknown) {
    const t = this.claimed(taskId, access);
    try {
      this.accept(t.id, raw);
    } catch (error) {
      this.setStatus(t.id, 'failed', {
        error: `invalid result: ${(error as Error).message}`,
      });
      throw new RoutineError('invalid result');
    }
  }

  fail(taskId: string, access: Access, error: string) {
    const t = this.claimed(taskId, access);
    this.setStatus(t.id, 'failed', { error: error.slice(0, 1_000) });
  }

  // --- helpers ------------------------------------------------------------

  private routine(id: string) {
    return this.o.db.select().from(routines).where(eq(routines.id, id)).get();
  }

  private task(id: string) {
    return this.o.db.select().from(tasks).where(eq(tasks.id, id)).get();
  }

  // A task about a message is only visible to keys that can see its mailbox.
  private visible(t: TaskRow, access: Access) {
    if (t.personId !== access.personId) return false;
    if (!t.messageId) return true;
    const message = this.o.mail.message(t.messageId);
    return !message || access.mailboxIds.includes(message.mailboxId);
  }

  private reviewable(id: string, access: Access) {
    const t = this.task(id);
    if (!t || !this.visible(t, access) || t.status !== 'review')
      throw new RoutineError('not found');
    return t;
  }

  private claimed(id: string, access: Access) {
    const t = this.task(id);
    if (
      !t ||
      !this.visible(t, access) ||
      t.status !== 'running' ||
      t.claimedBy === 'server'
    ) {
      throw new RoutineError('not found');
    }
    return t;
  }

  private setStatus(
    id: string,
    status: TaskStatus,
    extra: Partial<TaskRow> = {},
  ) {
    this.o.db
      .update(tasks)
      .set({ ...extra, status, updatedAt: new Date() })
      .where(eq(tasks.id, id))
      .run();
  }

  private toTask(t: TaskRow): Task {
    const r = this.routine(t.routineId);
    return {
      id: t.id,
      routineId: t.routineId,
      routineName: r?.name ?? '',
      skill: r?.skill ?? '',
      bot: r?.bot ?? '',
      where: r?.where ?? 'server',
      status: t.status,
      messageId: t.messageId,
      result: t.result ?? null,
      error: t.error ?? null,
      claimedBy: t.claimedBy ?? null,
      createdAt: t.createdAt.toISOString(),
      updatedAt: t.updatedAt.toISOString(),
    };
  }
}

function matches(
  trigger: Extract<RoutineInput['trigger'], { kind: 'message' }>,
  message: MessageRow,
  decision: TriageDecision,
): boolean {
  const lower = (s: string) => s.toLowerCase();
  if (trigger.triage && trigger.triage !== decision.action.kind) return false;
  if (trigger.label) {
    const labels = [
      ...message.labels,
      ...(decision.action.kind === 'label' ? [decision.action.label] : []),
    ];
    if (!labels.some((l) => lower(l) === lower(trigger.label!))) return false;
  }
  if (
    trigger.from &&
    !lower(`${message.from.name ?? ''} ${message.from.email}`).includes(
      lower(trigger.from),
    )
  ) {
    return false;
  }
  if (
    trigger.subject &&
    !lower(message.subject).includes(lower(trigger.subject))
  )
    return false;
  return true;
}

function toRoutine(r: RoutineRow) {
  return {
    id: r.id,
    name: r.name,
    trigger: r.trigger,
    skill: r.skill,
    bot: r.bot,
    where: r.where,
    fallbackAfterHours: r.fallbackAfterHours ?? null,
    approval: r.approval,
    enabled: r.enabled,
  };
}
