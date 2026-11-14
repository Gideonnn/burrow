import { claimedTask, searchResponse } from '@burrow/contracts';
import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { testHousehold } from '../testing';

const claimed = z.array(claimedTask);

// Three directions of meaning; a vector points mostly along one.
const along = (axis: number) =>
  Array.from({ length: 768 }, (_, i) => (i === axis ? 1 : i < 3 ? 0.1 : 0));

async function setup() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const home = h.mailbox(gideon.id, 'gideon@example.com');
  const token = h.key(gideon.id, ['read', 'tasks']);
  const post = (path: string, body: unknown = {}) =>
    h.call(token, path, { method: 'POST', body: JSON.stringify(body) });
  h.provider(home.id).deliver({
    subject: 'Uw energierekening',
    bodyText: 'Het voorschot gaat omhoog.',
    receivedAt: new Date('2026-09-01T08:00:00Z'),
  });
  h.provider(home.id).deliver({
    subject: 'Zomerkamp aanmelding',
    bodyText: 'De kinderen gaan in juli.',
    receivedAt: new Date('2026-10-01T08:00:00Z'),
  });
  await h.mail.sync(home.id);
  const claim = async (models: string[]) =>
    claimed.parse(
      await (
        await post('/api/runner/claim', {
          runner: 'MacBook',
          kinds: ['*'],
          queues: ['local'],
          models,
          max: 5,
        })
      ).json(),
    );
  return { ...h, gideon, home, token, post, claim };
}

describe('vectors for search by meaning', () => {
  it('asks a Mac with the embedding model for the vectors of indexed mail, newest first', async () => {
    const s = await setup();
    expect(await s.claim(['ollama:embeddinggemma'])).toEqual([]);
    s.platform.settings.update(s.gideon.id, { 'hedwig.facts': true });
    expect(
      await s
        .claim(['ollama:gemma4:26b-a4b'])
        .then((t) => t.map((x) => x.task.kind)),
    ).not.toContain('hedwig.embed');

    const [task] = (await s.claim(['ollama:embeddinggemma'])).filter(
      (t) => t.task.kind === 'hedwig.embed',
    );
    expect(task!.request).toMatchObject({
      model: 'ollama:embeddinggemma',
      agent: 'local',
      embed: true,
    });
    const { texts, dims } = JSON.parse(task!.request.prompt) as {
      texts: string[];
      dims: number;
    };
    expect(dims).toBe(256);
    expect(texts[0]).toContain('Zomerkamp aanmelding');
    expect(texts[1]).toContain('Uw energierekening');

    const done = await s.post(`/api/runner/tasks/${task!.task.id}/complete`, {
      vectors: [along(0), along(1)],
    });
    expect(done.status).toBe(200);
    expect(
      (await s.claim(['ollama:embeddinggemma'])).filter(
        (t) => t.task.kind === 'hedwig.embed',
      ),
    ).toEqual([]);

    // A question about money finds the energy bill by meaning alone.
    s.decisions.push({
      groups: [['kosten']],
      people: [],
      from: null,
      after: null,
      before: null,
      folder: null,
      roles: null,
      unreadOnly: false,
      hasAttachments: false,
      categories: null,
      includeLow: false,
      answer: false,
      explanation: 'Kosten',
    });
    const res = await s.call(s.token, '/api/search/ai', {
      method: 'POST',
      body: JSON.stringify({
        question: 'wat gaan we meer betalen?',
        vector: { model: 'ollama:embeddinggemma', values: along(1) },
      }),
    });
    const found = searchResponse.parse(await res.json());
    expect(found.results[0]!.subject).toBe('Uw energierekening');
  });

  it('goes before mail facts, which always has work', async () => {
    const s = await setup();
    s.platform.settings.update(s.gideon.id, { 'hedwig.facts': true });
    const res = await s.post('/api/runner/claim', {
      runner: 'MacBook',
      kinds: ['*'],
      queues: ['local'],
      models: ['ollama:gemma4:26b-a4b', 'ollama:embeddinggemma'],
      max: 1,
    });
    const [first] = claimed.parse(await res.json());
    expect(first!.task.kind).toBe('hedwig.embed');
  });

  // A runner's JSON decoder rejects half an emoji; one such mail stuck the
  // runner on the same batch for days.
  it('never cuts a character in half where it shortens a body', async () => {
    const s = await setup();
    s.platform.settings.update(s.gideon.id, { 'hedwig.facts': true });
    s.provider(s.home.id).deliver({
      subject: 'Groeten uit Texel',
      bodyText: `${'a'.repeat(399)}😀 tot snel`,
      receivedAt: new Date('2026-11-01T08:00:00Z'),
    });
    await s.mail.sync(s.home.id);
    const [task] = (await s.claim(['ollama:embeddinggemma'])).filter(
      (t) => t.task.kind === 'hedwig.embed',
    );
    const { texts } = JSON.parse(task!.request.prompt) as { texts: string[] };
    expect(texts[0]).toContain('Groeten uit Texel');
    expect(texts[0]).not.toMatch(/\p{Cs}/u);
  });

  it('retries a failed batch one mail at a time and skips a mail that keeps failing', async () => {
    const s = await setup();
    s.platform.settings.update(s.gideon.id, { 'hedwig.facts': true });
    const embedTasks = async () =>
      (await s.claim(['ollama:embeddinggemma'])).filter(
        (t) => t.task.kind === 'hedwig.embed',
      );
    const subjects = (t: { request: { prompt: string } }) =>
      (JSON.parse(t.request.prompt) as { texts: string[] }).texts.map((x) =>
        x.includes('Zomerkamp') ? 'Zomerkamp' : 'Energie',
      );
    const fail = (id: string) =>
      s.post(`/api/runner/tasks/${id}/fail`, { error: 'Ollama faalde' });

    const [batch] = await embedTasks();
    expect(subjects(batch!)).toEqual(['Zomerkamp', 'Energie']);
    await fail(batch!.task.id);

    const [broken, healthy, ...rest] = await embedTasks();
    expect(rest).toEqual([]);
    expect(subjects(broken!)).toEqual(['Zomerkamp']);
    expect(subjects(healthy!)).toEqual(['Energie']);
    await fail(broken!.task.id);
    const done = await s.post(
      `/api/runner/tasks/${healthy!.task.id}/complete`,
      { vectors: [along(1)] },
    );
    expect(done.status).toBe(200);

    // Two failed attempts: the broken mail is skipped.
    expect(await embedTasks()).toEqual([]);
  });

  it('refuses an answer with the wrong number of vectors', async () => {
    const s = await setup();
    s.platform.settings.update(s.gideon.id, { 'hedwig.facts': true });
    const [task] = (await s.claim(['ollama:embeddinggemma'])).filter(
      (t) => t.task.kind === 'hedwig.embed',
    );
    const res = await s.post(`/api/runner/tasks/${task!.task.id}/complete`, {
      vectors: [along(0)],
    });
    expect(res.status).toBeGreaterThanOrEqual(400);
  });
});
