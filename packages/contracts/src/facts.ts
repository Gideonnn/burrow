import { z } from 'zod';

// What a message is, for search and for agents that should not read mail.
export const factCategory = z.enum([
  'personal',
  'work',
  'school',
  'order',
  'shipping',
  'invoice',
  'bank',
  'travel',
  'appointment',
  'government',
  'health',
  'newsletter',
  'promotion',
  'notification',
  'account',
  'code',
  'other',
]);
export type FactCategory = z.infer<typeof factCategory>;

export const factPriority = z.enum(['low', 'normal', 'high']);
export type FactPriority = z.infer<typeof factPriority>;

export const amount = z.object({
  value: z.number(),
  currency: z.string().max(3),
});

// The facts about one message, derived from it and therefore as untrusted as
// the message itself. Rules decide `sensitive`; a model can only add to it.
export const messageFacts = z.object({
  category: factCategory.nullable(),
  priority: factPriority.nullable(),
  summary: z.string().nullable(),
  sensitive: z.boolean(),
  // Kinds like github-token or iban, never the values.
  sensitiveKinds: z.array(z.string()),
  people: z.array(z.string()),
  organisations: z.array(z.string()),
  amounts: z.array(amount),
  dates: z.array(z.string()),
  keywords: z.array(z.string()),
  // Where category and summary came from.
  source: z.enum(['rules', 'template', 'model']),
});
export type MessageFacts = z.infer<typeof messageFacts>;

const short = z.string().max(60);
const isoDay = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);

// What a model answers for one message. Ollama constrains the answer to this
// schema; the server trims what is too long before it checks.
export const factsAnswer = z.object({
  category: factCategory,
  priority: factPriority,
  sensitive: z.boolean(),
  summary: z.string().max(200),
  people: z.array(short).max(10),
  organisations: z.array(short).max(10),
  amounts: z.array(amount).max(5),
  dates: z.array(isoDay).max(5),
  keywords: z.array(z.string().max(30)).max(15),
});
export type FactsAnswer = z.infer<typeof factsAnswer>;

// What Haiku answers for a batch of templates: one entry per template number.
export const templatesAnswer = z.object({
  templates: z
    .array(
      z.object({
        n: z.number().int().min(0),
        category: factCategory,
        priority: factPriority,
        summary: z.string().max(120),
        organisation: z.string().max(60),
        keywords: z.array(z.string().max(30)).max(15),
      }),
    )
    .max(50),
});
export type TemplatesAnswer = z.infer<typeof templatesAnswer>;
