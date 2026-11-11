import type { ListScope, ResumePoint } from '@burrow/contracts';
import { type CatalogueTitle, overlap, refKey } from './catalogue';
import type { lumosRequests, lumosVerdicts } from './schema';

export type VerdictRow = typeof lumosVerdicts.$inferSelect;

// What one request needs to know about lists and verdicts, read once.
export type Context = {
  scope: ListScope;
  shared: Set<string>;
  mine: Set<string>;
  pass: Map<string, VerdictRow>;
  taste: Map<string, VerdictRow>;
  requests: Map<string, typeof lumosRequests.$inferSelect>;
};

export type Pool = Map<string, CatalogueTitle>;

export const listedIn = (ctx: Context) =>
  ctx.scope === 'shared' ? ctx.shared : ctx.mine;

// The provider's popularity, the scope's list, and "more/less like this".
// "Seen" and "not now" only hide a title; they never weigh others down.
export function rank(
  t: CatalogueTitle,
  ctx: Context,
  pool: Pool,
  watched: CatalogueTitle[] = [],
) {
  const key = refKey(t);
  let score = t.popularity;
  // What the household watched to the end counts as a light "more like this".
  for (const source of watched) {
    if (refKey(source) !== key) score += overlap(source, t) * 0.3;
  }
  if (listedIn(ctx).has(key)) score += 2;
  if (ctx.scope === 'shared' && ctx.mine.has(key)) score += 1;
  for (const verdict of ctx.taste.values()) {
    const source = pool.get(refKey(verdict));
    if (!source) continue;
    const sign = verdict.kind === 'more-like-this' ? 1 : -1;
    score +=
      refKey(source) === key ? sign * 4 : sign * overlap(source, t) * 1.2;
  }
  return score;
}

export function matchOf(t: CatalogueTitle, ctx: Context, pool: Pool) {
  const key = refKey(t);
  if (ctx.scope === 'shared' && ctx.shared.has(key)) return 'Op onze lijst';
  if (ctx.mine.has(key)) return 'Op jouw lijst';
  let best: { title: string; shared: number } | undefined;
  for (const verdict of ctx.taste.values()) {
    if (verdict.kind !== 'more-like-this') continue;
    const source = pool.get(refKey(verdict));
    if (!source || refKey(source) === key) continue;
    const shared = overlap(source, t);
    if (shared > 0 && (!best || shared > best.shared)) {
      best = { title: source.title, shared };
    }
  }
  return best ? `Lijkt op ${best.title}` : null;
}

// What "Meer zoals" starts from: the newest "more like this", else the top
// of the list, else the top pick.
export function seedOf(
  ctx: Context,
  pool: Pool,
  list: CatalogueTitle[],
  ranked: CatalogueTitle[],
) {
  for (const verdict of ctx.taste.values()) {
    const source = pool.get(refKey(verdict));
    if (verdict.kind === 'more-like-this' && source) return source;
  }
  return list[0] ?? ranked[0];
}

const minutes = (s: number) => Math.max(1, Math.round(s / 60));

// "Nog 50 min", or for a series "S1E4 De dijk, nog 40 min".
export function resumeLine(r: ResumePoint) {
  const left =
    r.runtimeSeconds && r.positionSeconds
      ? `nog ${minutes(r.runtimeSeconds - r.positionSeconds)} min`
      : null;
  if (!r.episode) return left ? `N${left.slice(1)}` : 'Verder kijken';
  const e = r.episode;
  const name = `S${e.season}E${e.number}${e.title ? ` ${e.title}` : ''}`;
  return left ? `${name}, ${left}` : name;
}

// A small seeded random, so "Verras me" is the same until the seed changes.
export function mulberry(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
