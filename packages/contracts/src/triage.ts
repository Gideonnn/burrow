import { z } from 'zod';
import { messageSummary, triageAction } from './mail';

// What a bot must answer for one message (the Sorting Hat skill's output).
export const triageDecision = z.object({
  action: triageAction,
  reason: z.string().min(1).max(400),
  unsure: z.boolean().default(false),
});
export type TriageDecision = z.infer<typeof triageDecision>;

// `doubt`: the bot thought spam but was unsure, so the mail stays in the inbox
// until the person decides.
export const triageStatus = z.enum([
  'applied',
  'kept',
  'pending-review',
  'doubt',
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

// A sender the person called spam or not spam; triage applies it before the
// bot runs. `sender` is an address, or a domain for bulk mail.
export const ruleKind = z.enum(['spam', 'not-spam']);
export type RuleKind = z.infer<typeof ruleKind>;

export const learnedRule = z.object({
  id: z.string(),
  text: z.string(),
  // Null for rules from before senders were kept apart.
  kind: ruleKind.nullable(),
  sender: z.string().nullable(),
  createdAt: z.iso.datetime(),
});
export type LearnedRule = z.infer<typeof learnedRule>;

// What the bot offers next to a message: a short summary for long mail, and
// complete replies the owner can send after reading them.
export const messageInsights = z.object({
  summary: z.string().nullable(),
  replies: z
    .array(
      z.object({ label: z.string().min(1).max(40), body: z.string().min(1) }),
    )
    .max(3),
});
export type MessageInsights = z.infer<typeof messageInsights>;
