import { describe, expect, it } from 'vitest';
import { testHousehold } from './testing';

// How fast the routes the Macs lean on answer, with the fixture catalogue
// in memory: a ceiling on the server's own work, apart from Seerr and the
// network. A page that opens from a cache still waits for these the first
// time, so they must stay well under a blink.

const ROUNDS = 25;

async function measure(work: () => Promise<unknown>) {
  const times: number[] = [];
  await work();
  for (let i = 0; i < ROUNDS; i++) {
    const start = performance.now();
    await work();
    times.push(performance.now() - start);
  }
  times.sort((a, b) => a - b);
  return {
    median: times[Math.floor(times.length / 2)] ?? 0,
    p95: times[Math.floor(times.length * 0.95)] ?? 0,
  };
}

describe('server latency on the fixture catalogue', () => {
  const h = testHousehold();
  const ada = h.person('Ada');
  const key = h.key(ada.id, ['read', 'organize']);
  const get = (path: string) => async () => {
    const res = await h.call(key, path);
    expect(res.status).toBe(200);
    await res.json();
  };

  it.each([
    ['the rows of Ontdekken', '/api/lumos/rows', 40],
    ['a title with its details', '/api/lumos/titles/movie/9000001', 15],
    ['more like a title', '/api/lumos/similar/movie/9000001', 15],
    ['a search', '/api/lumos/search?q=komedie', 15],
    ['a shelf of films', '/api/lumos/browse?type=movie&sort=top', 15],
    ['the Zoeker', '/api/lumos/explore?seed=3', 60],
    ['a person', '/api/lumos/credits/fx-andy-samberg', 15],
    ['the list', '/api/lumos/lists/shared', 10],
    ['who I am', '/api/me', 10],
    ['the outings', '/api/outings', 15],
  ])(
    '%s answers within %s ms at the 95th percentile',
    async (_, path, ceiling) => {
      const { median, p95 } = await measure(get(path));
      // eslint-disable-next-line no-console
      console.log(
        `${path}: median ${median.toFixed(1)} ms, p95 ${p95.toFixed(1)} ms`,
      );
      expect(p95).toBeLessThan(ceiling);
    },
  );

  it('a change to the list, with its event, stays under 20 ms', async () => {
    const { p95 } = await measure(async () => {
      const res = await h.call(
        key,
        '/api/lumos/lists/mine/items/movie/9000002',
        {
          method: 'PUT',
          body: '{}',
        },
      );
      expect(res.status).toBe(200);
      const change = (await res.json()) as { changeId: string };
      const undo = await h.call(
        key,
        `/api/lumos/changes/${change.changeId}/undo`,
        { method: 'POST' },
      );
      expect(undo.status).toBe(200);
    });
    expect(p95).toBeLessThan(20);
  });
});
