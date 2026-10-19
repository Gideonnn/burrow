import {
  type RoutineInput,
  type RoutineTrigger,
  type Subject,
  taskResult,
} from '@burrow/contracts';
import { and, eq } from 'drizzle-orm';
import { z } from 'zod';
import type { Catalog } from '../catalog/loadCatalog';
import type { Db } from '../db';
import { systemPrompt } from '../prompt';
import { routines } from '../schema';
import type { Subjects } from './subjects';
import type { TaskRow, Workers } from './tasks';

const resultSchema = z.toJSONSchema(taskResult, { target: 'draft-7' });

export class RoutineError extends Error {}

type RoutineRow = typeof routines.$inferSelect;

// A trigger kind a module offers, e.g. "message" from Hedwig: the module
// fires it with facts about the subject, and the matcher decides per routine.
export type TriggerType = {
  kind: string;
  matches: (trigger: RoutineTrigger, facts: unknown) => boolean;
};

export type OwnerContext = {
  name: string;
  instructions: string;
  language: string;
};

export type RoutinesOptions = {
  db: Db;
  catalog: Catalog;
  workers: Workers;
  subjects: Subjects;
  owner: (personId: string) => OwnerContext;
};

// Routines (Portkey) turn triggers into tasks: a bot with one skill, on the
// server or on a client app, returning a proposal (summary, fields, provider
// operations, a draft) that is applied after approval.
export class Routines {
  private readonly triggers = new Map<string, TriggerType>();

  constructor(private readonly o: RoutinesOptions) {
    o.workers.register({
      name: 'routine',
      describe: (t) => {
        const r = this.routine(t.routineId);
        return {
          title: r?.name ?? 'Routine',
          routineName: r?.name ?? '',
          bot: r?.bot,
          skill: r?.skill,
        };
      },
      agent: { request: (t) => this.request(t) },
      review: (t) => this.routine(t.routineId)?.approval ?? true,
      apply: async (t, result) => {
        if (!t.subjectType || !t.subjectId) return;
        await this.o.subjects
          .get(t.subjectType)
          ?.apply?.(t.subjectId, result, t);
      },
    });
  }

  registerTrigger(trigger: TriggerType) {
    if (trigger.kind === 'schedule' || this.triggers.has(trigger.kind)) {
      throw new RoutineError(`trigger "${trigger.kind}" is registered twice`);
    }
    this.triggers.set(trigger.kind, trigger);
  }

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
    if (
      input.trigger.kind !== 'schedule' &&
      !this.triggers.has(input.trigger.kind)
    ) {
      throw new RoutineError(
        `no module offers the trigger "${input.trigger.kind}"`,
      );
    }
    if (input.where === 'server' && input.fallbackAfterHours !== null) {
      throw new RoutineError('a fallback only applies to client routines');
    }
  }

  // --- triggers -----------------------------------------------------------

  // Called by a module when something happened to a subject of the person:
  // starts every enabled routine whose trigger matches.
  fire(kind: string, personId: string, subject: Subject, facts: unknown) {
    const trigger = this.triggers.get(kind);
    if (!trigger) return;
    for (const r of this.enabled(personId)) {
      if (r.trigger.kind === kind && trigger.matches(r.trigger, facts))
        this.start(r, subject);
    }
  }

  // Called every minute; starts schedule routines that are due.
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
  }

  private enabled(personId: string) {
    return this.o.db
      .select()
      .from(routines)
      .where(and(eq(routines.personId, personId), eq(routines.enabled, true)))
      .all();
  }

  private start(r: RoutineRow, subject: Subject | null): string {
    return this.o.workers.enqueue({
      kind: 'routine',
      routineId: r.id,
      personId: r.personId,
      subject,
      where: r.where,
      fallbackAt:
        r.where === 'client' && r.fallbackAfterHours !== null
          ? new Date(Date.now() + r.fallbackAfterHours * 3_600_000)
          : null,
    });
  }

  // The prompt is built here, also for client runners, so a client never needs
  // the bots, skills or the owner's instructions itself.
  private request(t: TaskRow) {
    const r = this.routine(t.routineId);
    if (!r) throw new RoutineError('the routine was removed');
    const bot = this.o.catalog.bots.get(r.bot);
    const skill = this.o.catalog.skills.get(r.skill);
    if (!bot || !skill) throw new RoutineError('bot or skill is gone');
    const owner = this.o.owner(t.personId);
    const task = `Run the routine "${r.name}" for`;
    const prompt =
      t.subjectType && t.subjectId
        ? this.o.subjects.get(t.subjectType)?.prompt(t.subjectId, {
            ownerName: owner.name,
            instructions: owner.instructions,
            language: owner.language,
            task,
          })
        : `${task} ${owner.name} on ${new Date().toISOString().slice(0, 10)}.\n\n## ${owner.name}'s instructions\n${owner.instructions || '(none)'}\n\nAnswer with JSON only, matching the schema. Write any text for people in ${owner.language}.`;
    if (!prompt) throw new RoutineError('the subject of this task is gone');
    return {
      model: bot.model,
      agent: bot.agent,
      system: systemPrompt(bot, [skill]),
      prompt,
      schema: resultSchema,
    };
  }

  private routine(id: string | null) {
    if (!id) return undefined;
    return this.o.db.select().from(routines).where(eq(routines.id, id)).get();
  }
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
