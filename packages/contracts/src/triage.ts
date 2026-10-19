import { z } from 'zod';
import { messageSummary, triageAction } from './mail';

// What a bot must answer for one message (the Sorting Hat skill's output).
export const triageDecision = z.object({
  action: triageAction,
  reason: z.string().min(1).max(400),
  unsure: z.boolean().default(false),
});
export type TriageDecision = z.infer<typeof triageDecision>;

export const triageStatus = z.enum([
  'applied',
  'kept',
  'pending-review',
  'confirmed',
  'restored',
]);
export type TriageStatus = z.infer<typeof triageStatus>;

export const filteredEntry = z.object({
  id: z.string(),
  bot: z.string(),
  action: triageAction,
  reason: z.string(),
  unsure: z.boolean(),
  // Plain descriptions of what happened at the provider, e.g. "label SPAM".
  serverOps: z.array(z.string()),
  createdAt: z.iso.datetime(),
  message: messageSummary,
});
export type FilteredEntry = z.infer<typeof filteredEntry>;

export const instructions = z.object({ text: z.string().max(10_000) });
export type Instructions = z.infer<typeof instructions>;

export const learnedRule = z.object({
  id: z.string(),
  text: z.string(),
  createdAt: z.iso.datetime(),
});
export type LearnedRule = z.infer<typeof learnedRule>;
