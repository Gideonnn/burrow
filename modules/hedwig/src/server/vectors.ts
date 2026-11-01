import type { Db } from '@burrow/platform';
import { eq, sql } from 'drizzle-orm';
import { messageVectors } from './schema';

// Vectors are kept short: the first DIMS numbers of a Matryoshka model
// (embeddinggemma) carry most of the meaning, and 51,000 messages then take
// about 50 MB of memory instead of 160.
export const DIMS = 256;

export function normalised(values: readonly number[]): Float32Array {
  const v = Float32Array.from(values.slice(0, DIMS));
  let norm = 0;
  for (const x of v) norm += x * x;
  norm = Math.sqrt(norm) || 1;
  for (let i = 0; i < v.length; i++) v[i]! /= norm;
  return v;
}

type Loaded = { ids: string[]; data: Float32Array };

// Every vector of one model in memory, searched by brute force: a dot product
// over 50,000 vectors takes a few milliseconds, no index needed.
export class VectorIndex {
  private loaded = new Map<string, Loaded>();
  // Models with vectors stored since they were loaded.
  private stale = new Set<string>();

  constructor(private readonly db: Db) {}

  store(model: string, messageId: string, values: readonly number[]) {
    const vector = Buffer.from(normalised(values).buffer);
    this.db
      .insert(messageVectors)
      .values({ messageId, model, vector })
      .onConflictDoUpdate({
        target: messageVectors.messageId,
        set: { model, vector },
      })
      .run();
    this.stale.add(model);
  }

  count(model: string): number {
    return this.db.get<{ n: number }>(
      sql`select count(*) as n from message_vectors where model = ${model}`,
    )!.n;
  }

  // The closest messages first, with their similarity.
  nearest(
    model: string,
    query: readonly number[],
    limit: number,
  ): { id: string; score: number }[] {
    const index = this.index(model);
    if (!index.ids.length) return [];
    const q = normalised(query);
    const dims = q.length;
    const scores = new Float32Array(index.ids.length);
    for (let i = 0; i < index.ids.length; i++) {
      let s = 0;
      const off = i * DIMS;
      for (let d = 0; d < dims; d++) s += index.data[off + d]! * q[d]!;
      scores[i] = s;
    }
    const order = [...scores.keys()]
      .sort((a, b) => scores[b]! - scores[a]!)
      .slice(0, limit);
    return order.map((i) => ({ id: index.ids[i]!, score: scores[i]! }));
  }

  private index(model: string): Loaded {
    const cached = this.loaded.get(model);
    if (cached && !this.stale.has(model)) return cached;
    this.stale.delete(model);
    const rows = this.db
      .select({ id: messageVectors.messageId, vector: messageVectors.vector })
      .from(messageVectors)
      .where(eq(messageVectors.model, model))
      .all();
    const data = new Float32Array(rows.length * DIMS);
    rows.forEach((r, i) => {
      // A copy, since SQLite's buffer need not start on a four-byte boundary.
      const v = new Float32Array(Uint8Array.from(r.vector).buffer);
      data.set(v.subarray(0, DIMS), i * DIMS);
    });
    const loaded = { ids: rows.map((r) => r.id), data };
    this.loaded.set(model, loaded);
    return loaded;
  }
}
