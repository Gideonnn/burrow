import { claimedTask, runnersResponse } from '@burrow/contracts';
import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { testHousehold } from '../testing';

const claimed = z.array(claimedTask);

function setup() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const eva = h.person('Eva');
  const token = h.key(gideon.id, ['read', 'tasks']);
  const evaToken = h.key(eva.id, ['read', 'organize', 'tasks']);
  const request = () => ({
    model: 'haiku',
    system: 'You test.',
    prompt: 'Do it.',
    schema: { type: 'object' },
  });
  // Agent kinds for the tests: a cloud one and one on the local queue.
  h.workers.register({
    name: 'test.cloud',
    describe: () => ({ title: 'Cloud work' }),
    agent: { request },
  });
  h.workers.register({
    name: 'test.local',
    queue: 'local',
    model: 'ollama:gemma4',
    describe: () => ({ title: 'Local work' }),
    agent: {
      request: () => ({ ...request(), model: 'ollama:gemma4', agent: 'local' }),
    },
  });
  const post = (key: string, path: string, body: unknown = {}) =>
    h.call(key, path, { method: 'POST', body: JSON.stringify(body) });
  const claim = async (key: string, offer: object = {}) =>
    claimed.parse(
      await (
        await post(key, '/api/runner/claim', {
          runner: 'MacBook',
          kinds: ['*'],
          ...offer,
        })
      ).json(),
    );
  const runners = async (key: string) =>
    runnersResponse.parse(await (await h.call(key, '/api/runners')).json());
  return { ...h, gideon, eva, token, evaToken, post, claim, runners };
}

const mac = { queues: ['local', 'cloud'], models: ['ollama:gemma4'] };

describe('runners', () => {
  it('registers a runner on its first claim, next to the server', async () => {
    const s = setup();
    await s.claim(s.token, mac);
    const { runners } = await s.runners(s.token);
    expect(runners.map((r) => [r.name, r.mine, r.online])).toEqual([
      ['server', false, true],
      ['MacBook', true, true],
    ]);
    expect(runners[1]).toMatchObject({
      personName: 'Gideon',
      queues: ['local', 'cloud'],
      models: ['ollama:gemma4'],
    });
  });

  it('hands out the highest priority first', async () => {
    const s = setup();
    const base = {
      kind: 'test.cloud',
      personId: s.gideon.id,
      where: 'client' as const,
    };
    s.workers.enqueue({ ...base, priority: 'low' });
    const urgent = s.workers.enqueue({ ...base, priority: 'urgent' });
    s.workers.enqueue(base);
    const [first] = await s.claim(s.token, { max: 1 });
    expect(first?.task).toMatchObject({ id: urgent, priority: 'urgent' });
  });

  it('keeps local work on a device of its person with a local model', async () => {
    const s = setup();
    s.workers.enqueue({ kind: 'test.local', personId: s.gideon.id });
    expect(await s.claim(s.token)).toEqual([]);
    expect(await s.claim(s.evaToken, mac)).toEqual([]);
    expect(
      await s.claim(s.token, { ...mac, models: ['ollama:other'] }),
    ).toEqual([]);
    const [task] = await s.claim(s.token, mac);
    expect(task?.request).toMatchObject({
      model: 'ollama:gemma4',
      agent: 'local',
    });
    await s.workers.drain();
    expect(s.agentRequests).toEqual([]);
  });

  it('runs cloud work of others only when they allow it, a setting only they change', async () => {
    const s = setup();
    s.workers.enqueue({
      kind: 'test.cloud',
      personId: s.eva.id,
      where: 'client',
    });
    expect(await s.claim(s.token)).toEqual([]);

    const admin = s.key(s.gideon.id, ['read', 'organize', 'admin']);
    const forEva = await s.call(
      admin,
      `/api/admin/people/${s.eva.id}/settings`,
      {
        method: 'PATCH',
        body: JSON.stringify({ values: { 'platform.shareCloudWork': true } }),
      },
    );
    expect(forEva.status).toBe(403);
    await s.call(s.evaToken, '/api/me/settings', {
      method: 'PATCH',
      body: JSON.stringify({ values: { 'platform.shareCloudWork': true } }),
    });

    const [task] = await s.claim(s.token);
    expect(task).toBeDefined();
    const done = await s.post(
      s.token,
      `/api/runner/tasks/${task!.task.id}/complete`,
      {
        summary: 'Klaar.',
      },
    );
    expect(done.status).toBe(200);
  });

  it('gives a paused runner nothing, and only its person pauses it', async () => {
    const s = setup();
    await s.claim(s.token);
    const mine = (await s.runners(s.token)).runners.find((r) => r.mine)!;
    const byEva = await s.call(s.evaToken, `/api/runners/${mine.id}`, {
      method: 'PATCH',
      body: JSON.stringify({ paused: true }),
    });
    expect(byEva.status).toBe(404);
    await s.call(s.token, `/api/runners/${mine.id}`, {
      method: 'PATCH',
      body: JSON.stringify({ paused: true }),
    });
    s.workers.enqueue({
      kind: 'test.cloud',
      personId: s.gideon.id,
      where: 'client',
    });
    expect(await s.claim(s.token)).toEqual([]);
    expect((await s.runners(s.token)).work).toEqual([
      {
        queue: 'cloud',
        kind: 'test.cloud',
        title: 'test.cloud',
        waiting: 1,
        done: null,
      },
    ]);
  });

  it('lets only the key that claimed a task finish it', async () => {
    const s = setup();
    s.workers.enqueue({
      kind: 'test.cloud',
      personId: s.gideon.id,
      where: 'client',
    });
    const [task] = await s.claim(s.token);
    const other = s.key(s.gideon.id, ['read', 'tasks']);
    const res = await s.post(
      other,
      `/api/runner/tasks/${task!.task.id}/complete`,
      {
        summary: 'Niet van mij.',
      },
    );
    expect(res.status).toBe(404);
  });
  it('treats a Mac that calls itself server like any other Mac', async () => {
    const s = setup();
    s.workers.enqueue({
      kind: 'test.cloud',
      personId: s.gideon.id,
      where: 'client',
    });
    const [task] = await s.claim(s.token, { runner: 'server' });
    const res = await s.post(
      s.token,
      `/api/runner/tasks/${task!.task.id}/complete`,
      {
        summary: 'Klaar.',
      },
    );
    expect(res.status).toBe(200);
  });
});
