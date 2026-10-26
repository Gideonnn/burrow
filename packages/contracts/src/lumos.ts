import { z } from 'zod';
import { person } from './access';

// Films and series to watch together. The catalogue comes from a provider on
// the server (Seerr, which serves TMDB's data; isolated fixtures in
// development); lists, verdicts and requests are Lumos's own.

export const mediaType = z.enum(['movie', 'tv']);
export type MediaType = z.infer<typeof mediaType>;

// `fixture` is test data that must never pass for the real catalogue.
export const dataOrigin = z.enum(['live', 'fixture']);
export type DataOrigin = z.infer<typeof dataOrigin>;

// `shared` is the household's list; `mine` the key's person's own.
export const listScope = z.enum(['shared', 'mine']);
export type ListScope = z.infer<typeof listScope>;

export const availability = z.enum([
  'not-requested',
  'requested',
  'waiting-for-release',
  'downloading',
  'importing',
  'import-problem',
  'available',
  'partially-available',
]);
export type Availability = z.infer<typeof availability>;

// `seen` hides a title without counting as dislike; the taste kinds weigh
// similar titles up or down.
export const verdictKind = z.enum([
  'not-now',
  'seen',
  'more-like-this',
  'less-like-this',
]);
export type VerdictKind = z.infer<typeof verdictKind>;

export const passKinds = ['not-now', 'seen'] as const;
export const tasteKinds = ['more-like-this', 'less-like-this'] as const;

export const verdictRef = z.object({
  id: z.string(),
  kind: verdictKind,
  reason: z.string().nullable(),
});
export type VerdictRef = z.infer<typeof verdictRef>;

export const titleSummary = z.object({
  mediaType,
  tmdbId: z.number().int(),
  title: z.string(),
  year: z.number().int().nullable(),
  // Metadata only; nothing is ever filtered on it.
  runtimeMinutes: z.number().int().nullable(),
  seasons: z.number().int().nullable(),
  genres: z.array(z.string()),
  traits: z.array(z.string()),
  language: z.string().nullable(),
  poster: z.string().nullable(),
  backdrop: z.string().nullable(),
  availability,
  hasTrailer: z.boolean(),
  // In the scope the request asked for.
  onList: z.boolean(),
  onShared: z.boolean(),
  onMine: z.boolean(),
  pass: verdictRef.nullable(),
  taste: verdictRef.nullable(),
  // Why it is proposed, kept apart from scores.
  match: z.string().nullable(),
});
export type TitleSummary = z.infer<typeof titleSummary>;

export const score = z.object({
  source: z.string(),
  // e.g. "Critics"; null when the source has one score.
  label: z.string().nullable(),
  value: z.number(),
  scale: z.enum(['ten', 'percent']),
  votes: z.number().int().nullable(),
  // "2,500+": the source gives only a lower bound.
  votesAtLeast: z.boolean(),
  asOf: z.string(),
  url: z.string().nullable(),
});
export type Score = z.infer<typeof score>;

export const snippet = z.object({
  source: z.string(),
  author: z.string().nullable(),
  url: z.string(),
  quote: z.string(),
  language: z.string(),
  checkedAt: z.string(),
});
export type Snippet = z.infer<typeof snippet>;

export const trailer = z.discriminatedUnion('provider', [
  z.object({
    provider: z.literal('youtube'),
    key: z.string(),
    url: z.string(),
    publisher: z.string(),
    language: z.string().nullable(),
    checkedAt: z.string(),
  }),
  z.object({
    provider: z.literal('direct'),
    url: z.string(),
    // The page to open for full screen or a better quality.
    sourceUrl: z.string().nullable(),
    publisher: z.string(),
    language: z.string().nullable(),
    license: z.string().nullable(),
    checkedAt: z.string(),
  }),
]);
export type Trailer = z.infer<typeof trailer>;

export const creditRole = z.enum(['director', 'creator', 'cast']);
export const credit = z.object({
  id: z.string(),
  name: z.string(),
  role: creditRole,
});
export type Credit = z.infer<typeof credit>;

// Lumos's request to the media server for a title on a list: `pending`
// waits out the undo window or a retry, `exists` means the server already
// had or awaited it, `dropped` that the wish was undone before it left.
export const requestStatus = z.enum([
  'pending',
  'sent',
  'exists',
  'dropped',
  'failed',
]);
export const requestState = z.object({
  status: requestStatus,
  seasons: z.array(z.number().int()).nullable(),
  error: z.string().nullable(),
  attempts: z.number().int(),
  nextAttemptAt: z.string().nullable(),
  updatedAt: z.string(),
});
export type RequestState = z.infer<typeof requestState>;

// From the download client through Seerr; absent when nothing downloads.
export const download = z.object({
  progress: z.number().min(0).max(1),
  eta: z.string().nullable(),
});

export const titleDetail = titleSummary.extend({
  dataOrigin,
  synopsis: z.string().nullable(),
  synopsisLanguage: z.string().nullable(),
  credits: z.array(credit),
  scores: z.array(score),
  snippets: z.array(snippet),
  trailer: trailer.nullable(),
  stills: z.array(z.string()),
  // Credit for the stills, e.g. a licence.
  stillsCredit: z.string().nullable(),
  tmdbUrl: z.string().nullable(),
  request: requestState.nullable(),
  download: download.nullable(),
});
export type TitleDetail = z.infer<typeof titleDetail>;

export const rowStyle = z.enum(['wide', 'poster']);
export const titleRow = z.object({
  key: z.string(),
  title: z.string(),
  subtitle: z.string().nullable(),
  style: rowStyle,
  items: z.array(titleSummary),
  // Shown instead of hiding an empty row (the lists).
  empty: z.string().nullable(),
});
export type TitleRow = z.infer<typeof titleRow>;

export const rowsResponse = z.object({
  dataOrigin,
  rows: z.array(titleRow),
});
export type RowsResponse = z.infer<typeof rowsResponse>;

export const titleHit = z.object({
  title: titleSummary,
  // "Regie: …", "Kenmerk: …"; null for a title match.
  why: z.string().nullable(),
});
export const titleSearchResponse = z.object({
  dataOrigin,
  query: z.string(),
  hits: z.array(titleHit),
  credits: z.array(credit.omit({ role: true })),
});
export type TitleSearchResponse = z.infer<typeof titleSearchResponse>;

export const titlesResponse = z.object({
  dataOrigin,
  items: z.array(titleSummary),
});
export type TitlesResponse = z.infer<typeof titlesResponse>;

export const creditResponse = z.object({
  dataOrigin,
  credit: z.object({ id: z.string(), name: z.string() }),
  titles: z.array(titleSummary),
});

export const listEntry = z.object({
  title: titleSummary,
  addedBy: person,
  addedAt: z.string(),
  seasons: z.array(z.number().int()).nullable(),
});
export type ListEntry = z.infer<typeof listEntry>;

export const listResponse = z.object({
  scope: listScope,
  items: z.array(listEntry),
});
export type ListResponse = z.infer<typeof listResponse>;

export const putListItemRequest = z.object({
  seasons: z.array(z.number().int().min(0)).max(100).nullable().default(null),
});

export const verdictReason = z.string().trim().min(1).max(120);
export const createVerdictRequest = z.object({
  scope: listScope,
  mediaType,
  tmdbId: z.number().int(),
  kind: verdictKind,
  reason: verdictReason.nullable().default(null),
});
export type CreateVerdictRequest = z.input<typeof createVerdictRequest>;

export const verdict = z.object({
  id: z.string(),
  scope: listScope,
  kind: verdictKind,
  reason: z.string().nullable(),
  by: person,
  createdAt: z.string(),
  title: titleSummary,
});
export type Verdict = z.infer<typeof verdict>;

export const verdictsResponse = z.object({
  scope: listScope,
  items: z.array(verdict),
});

export const lumosStatus = z.object({
  // null: no catalogue is connected ("niet gekoppeld").
  dataOrigin: dataOrigin.nullable(),
  catalogue: z.string().nullable(),
  // Putting a title on a list asks the media server for it.
  requests: z.boolean(),
});
export type LumosStatus = z.infer<typeof lumosStatus>;

// Every change answers with the id that undoes it exactly, also when it
// touched a list and a verdict at once. Only its author can undo it.
export const lumosChange = z.object({ changeId: z.string() });
export type LumosChange = z.infer<typeof lumosChange>;
