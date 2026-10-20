import { z } from 'zod';
import { effort } from './catalog';
import { address, serverOp } from './mail';

// What starts a routine. New trigger kinds can be added here without touching
// the routines that already exist.
export const routineTrigger = z.discriminatedUnion('kind', [
  z.object({
    // A new message, after triage. Every given condition must hold.
    kind: z.literal('message'),
    label: z.string().min(1).optional(),
    triage: z
      .enum(['keep', 'spam', 'archive', 'needs-reply', 'label'])
      .optional(),
    from: z.string().min(1).optional(),
    subject: z.string().min(1).optional(),
  }),
  z.object({
    kind: z.literal('schedule'),
    everyMinutes: z.number().int().min(15),
  }),
  z.object({
    // A recording whose notes are ready (Pensieve), optionally only when the
    // title contains this text.
    kind: z.literal('recording'),
    title: z.string().min(1).optional(),
  }),
]);
export type RoutineTrigger = z.infer<typeof routineTrigger>;

// Where a task may run: on the server, or on a client app of the owner (for
// skills that need the owner's computer, like files in iCloud). A client task
// falls back to the server after `fallbackAfterHours` if no client picked it up.
export const taskWhere = z.enum(['server', 'client']);
export type TaskWhere = z.infer<typeof taskWhere>;

export const routineInput = z.object({
  name: z.string().trim().min(1).max(80),
  trigger: routineTrigger,
  skill: z.string().min(1),
  bot: z.string().min(1),
  where: taskWhere.default('server'),
  fallbackAfterHours: z.number().int().min(1).nullable().default(null),
  // When true, a person approves the result before anything happens.
  approval: z.boolean().default(true),
  enabled: z.boolean().default(true),
});
export type RoutineInput = z.infer<typeof routineInput>;

export const routine = routineInput.extend({ id: z.string() });
export type Routine = z.infer<typeof routine>;

// Operations a task result may ask for: never trash or sending.
export const taskOp = serverOp.refine(
  (o) => o.op !== 'trash',
  'tasks cannot delete mail',
);

// What a skill run returns. Everything is a proposal: ops and the draft only
// happen after approval (or right away for routines without approval).
export const taskResult = z.object({
  summary: z.string().min(1).max(2_000),
  fields: z.record(z.string(), z.string()).default({}),
  ops: z.array(taskOp).max(10).default([]),
  draft: z
    .object({
      to: z.array(address).min(1),
      subject: z.string(),
      body: z.string().min(1),
    })
    .nullable()
    .default(null),
});
export type TaskResult = z.infer<typeof taskResult>;

export const taskStatus = z.enum([
  'queued',
  'running',
  'review',
  'done',
  'failed',
  'rejected',
]);
export type TaskStatus = z.infer<typeof taskStatus>;

// What a task is about, owned by a module: a mail message, a recording.
export const subject = z.object({ type: z.string(), id: z.string() });
export type Subject = z.infer<typeof subject>;

export const task = z.object({
  id: z.string(),
  // The task kind, e.g. "routine" or "pensieve.transcribe".
  kind: z.string(),
  // What people see in a list: the routine's name or what the step does.
  title: z.string(),
  routineId: z.string().nullable(),
  routineName: z.string(),
  skill: z.string(),
  bot: z.string(),
  where: taskWhere,
  status: taskStatus,
  subject: subject.nullable(),
  // subject.id when the subject is a message, kept for older clients.
  messageId: z.string().nullable(),
  result: taskResult.nullable(),
  error: z.string().nullable(),
  claimedBy: z.string().nullable(),
  createdAt: z.iso.datetime(),
  updatedAt: z.iso.datetime(),
});
export type Task = z.infer<typeof task>;

// A task handed to a client runner, with the agent request already built by
// the server; the client only runs it with its own agent CLI.
export const claimedTask = z.object({
  task,
  request: z.object({
    model: z.string(),
    effort: effort.optional(),
    system: z.string(),
    prompt: z.string(),
    schema: z.record(z.string(), z.unknown()),
    // Which agent CLI the bot prefers; the runner falls back to another.
    // A Claude runner refuses `local`, which is only for a local model.
    agent: z.enum(['claude', 'codex', 'any', 'local']).default('any'),
    timeoutMs: z.number().int().positive().optional(),
  }),
});
export type ClaimedTask = z.infer<typeof claimedTask>;

// A client runner asks for tasks of the kinds it can run.
export const claimRequest = z.object({
  runner: z.string().min(1).max(80),
  max: z.number().int().min(1).max(5).default(2),
  kinds: z.array(z.string().min(1)).min(1).default(['routine']),
});
export type ClaimRequest = z.infer<typeof claimRequest>;
