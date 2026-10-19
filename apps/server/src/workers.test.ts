import { describe, expect, it } from 'vitest';
import { testHousehold } from './testing';

// A code task kind whose runs the test releases by hand.
function household(concurrencyProbe = { active: 0, max: 0 }) {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const releases: (() => void)[] = [];
  let failuresLeft = 0;
  h.workers.register({
    name: 'test.slow',
    describe: () => ({ title: 'Langzaam werk' }),
    attempts: 3,
    run: async () => {
      concurrencyProbe.active++;
      concurrencyProbe.max = Math.max(
        concurrencyProbe.max,
        concurrencyProbe.active,
      );
      await new Promise<void>((go) => releases.push(go));
      concurrencyProbe.active--;
      if (failuresLeft > 0) {
        failuresLeft--;
        throw new Error('network hiccup');
      }
      return { summary: 'klaar', fields: {}, ops: [], draft: null };
    },
  });
  const token = h.key(gideon.id, ['read', 'organize']);
  const releaseAll = async () => {
    while (releases.length || h.workers['running'].size) {
      releases.splice(0).forEach((go) => go());
      await new Promise((r) => setTimeout(r, 1));
    }
  };
  return {
    ...h,
    gideon,
    token,
    releaseAll,
    failNext: (n: number) => (failuresLeft = n),
  };
}

describe('the worker pool', () => {
  it('runs at most the configured number of tasks at once', async () => {
    const probe = { active: 0, max: 0 };
    const h = household(probe);
    for (let i = 0; i < 5; i++) {
      h.workers.enqueue({ kind: 'test.slow', personId: h.gideon.id });
    }
    await h.releaseAll();
    expect(probe.max).toBe(2);
    const list = (await (await h.call(h.token, '/api/tasks')).json()) as {
      status: string;
    }[];
    expect(list.map((t) => t.status)).toEqual(Array(5).fill('done'));
  });

  it('retries a failing code task, then reports why it gave up', async () => {
    const h = household();
    h.failNext(5);
    const id = h.workers.enqueue({ kind: 'test.slow', personId: h.gideon.id });
    await h.releaseAll();
    expect(h.workers.task(id)).toMatchObject({
      status: 'failed',
      attempts: 3,
      error: 'network hiccup',
    });

    h.failNext(0);
    const retry = await h.call(h.token, `/api/tasks/${id}/retry`, {
      method: 'POST',
    });
    expect(retry.status).toBe(200);
    await h.releaseAll();
    expect(h.workers.task(id)?.status).toBe('done');
  });

  it('picks up tasks that were running on the server when it stopped', async () => {
    const h = household();
    const id = h.workers.enqueue({ kind: 'test.slow', personId: h.gideon.id });
    // As if the process died mid-run: the row says running, nothing runs.
    h.workers['running'].clear();
    expect(h.workers.task(id)?.status).toBe('running');
    h.workers.recover();
    await h.releaseAll();
    expect(h.workers.task(id)?.status).toBe('done');
  });
});
