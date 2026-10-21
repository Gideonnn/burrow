import { z } from 'zod';

// The local queue holds raw, possibly sensitive content and only reaches a
// runner of the task's own person with a model on that device; the cloud
// queue holds redacted content any cloud agent may see.
export const queue = z.enum(['local', 'cloud']);
export type Queue = z.infer<typeof queue>;

// A runner claims the highest priority first, the oldest first within it.
export const taskPriority = z.enum(['low', 'normal', 'high', 'urgent']);
export type TaskPriority = z.infer<typeof taskPriority>;

// What a runner offers. Each claim is also its heartbeat, so a runner that
// starts claiming is registered; a later claim updates what it offers.
export const runnerOffer = z.object({
  queues: z.array(queue).min(1).default(['cloud']),
  // Cloud agent CLIs on the device.
  agents: z.array(z.enum(['claude', 'codex'])).default(['claude']),
  // Local models, as ollama:<name>.
  models: z
    .array(z.string().regex(/^ollama:.+/))
    .max(10)
    .default([]),
  concurrency: z.number().int().min(1).max(8).default(1),
});
export type RunnerOffer = z.infer<typeof runnerOffer>;

export const runner = z.object({
  id: z.string(),
  name: z.string(),
  // Whose device it is; null for the server's own pool.
  personName: z.string().nullable(),
  mine: z.boolean(),
  queues: z.array(queue),
  agents: z.array(z.string()),
  models: z.array(z.string()),
  kinds: z.array(z.string()),
  paused: z.boolean(),
  online: z.boolean(),
  lastSeenAt: z.iso.datetime().nullable(),
  // What it works on now, only for the key's own runners.
  doing: z.string().nullable(),
});
export type Runner = z.infer<typeof runner>;

// Work waiting for the key's person, per kind.
export const queueWork = z.object({
  queue,
  kind: z.string(),
  title: z.string(),
  waiting: z.number().int(),
  // For standing work: how much is done of the whole, e.g. indexed messages.
  done: z.number().int().nullable(),
});
export type QueueWork = z.infer<typeof queueWork>;

export const runnersResponse = z.object({
  runners: z.array(runner),
  work: z.array(queueWork),
});
export type RunnersResponse = z.infer<typeof runnersResponse>;

export const updateRunnerRequest = z.object({ paused: z.boolean() });
