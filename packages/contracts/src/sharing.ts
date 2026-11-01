import { z } from 'zod';
import { messageSummary } from './mail';

// `hedwig.share`: whether Winky looks for household mail, and whether he
// shares it himself.
export const shareMode = z.enum(['off', 'suggest', 'auto']);
export type ShareMode = z.infer<typeof shareMode>;

export const shareMessageRequest = z.object({ personId: z.string().min(1) });
export type ShareMessageRequest = z.infer<typeof shareMessageRequest>;

export const sharedResponse = z.object({
  withMe: z.array(messageSummary),
  byMe: z.array(messageSummary),
});
export type SharedResponse = z.infer<typeof sharedResponse>;

export const shareSuggestion = z.object({
  message: messageSummary,
  reason: z.string(),
});
export type ShareSuggestion = z.infer<typeof shareSuggestion>;

export const shareSuggestionsResponse = z.object({
  suggestions: z.array(shareSuggestion),
});
export type ShareSuggestionsResponse = z.infer<typeof shareSuggestionsResponse>;

// `always` holds for the sender: every later suggestion from them is shared,
// or with dismiss, none is made again.
export const shareDecisionRequest = z.object({
  decision: z.enum(['share', 'dismiss']),
  always: z.boolean().default(false),
});
export type ShareDecisionRequest = z.infer<typeof shareDecisionRequest>;

// What Winky answers for a batch of numbered mails.
export const shareAnswer = z.object({
  mails: z
    .array(
      z.object({
        n: z.number().int().min(1),
        share: z.boolean(),
        reason: z.string().max(60),
      }),
    )
    .max(50),
});
export type ShareAnswer = z.infer<typeof shareAnswer>;
