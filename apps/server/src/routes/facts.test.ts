import {
  claimedTask,
  messageSummary,
  runnersResponse,
  searchResponse,
} from '@burrow/contracts';
import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { testHousehold } from '../testing';

const claimed = z.array(claimedTask);
const IBAN = 'NL91ABNA0417164300';

async function setup() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const eva = h.person('Eva');
  const home = h.mailbox(gideon.id, 'gideon@example.com');
  const evas = h.mailbox(eva.id, 'eva@example.com');
  const token = h.key(gideon.id, ['read', 'organize', 'tasks']);
  const evaToken = h.key(eva.id, ['read', 'organize', 'tasks']);
  const post = (key: string, path: string, body: unknown = {}) =>
    h.call(key, path, { method: 'POST', body: JSON.stringify(body) });
  const indexing = (key: string, on = true) =>
    h.call(key, '/api/me/settings', {
      method: 'PATCH',
      body: JSON.stringify({ values: { 'hedwig.facts': on } }),
    });
  const deliver = async (
    mailboxId: string,
    message: Parameters<ReturnType<typeof h.provider>['deliver']>[0],
  ) => {
    h.provider(mailboxId).deliver(message);
    return (await h.mail.sync(mailboxId))[0]!;
  };
  // A Mac with Winky's model on the local queue.
  const claim = async (key: string) =>
    claimed.parse(
      await (
        await post(key, '/api/runner/claim', {
          runner: 'MacBook',
          kinds: ['*'],
          queues: ['local'],
          models: ['ollama:gemma4:26b-a4b'],
          max: 5,
        })
      ).json(),
    );
  const search = async (key: string, q: string, extra = '') =>
    searchResponse.parse(
      await (
        await h.call(key, `/api/search?q=${encodeURIComponent(q)}${extra}`)
      ).json(),
    ).results;
  return {
    ...h,
    gideon,
    eva,
    home,
    evas,
    token,
    evaToken,
    post,
    indexing,
    deliver,
    claim,
    search,
  };
}

const answer = {
  category: 'invoice',
  priority: 'high',
  sensitive: false,
  summary:
    'Factuur van de tandarts voor de controle, te betalen voor 1 november.',
  people: ['Dr. Jansen'],
  organisations: ['Tandartspraktijk Lindelaan'],
  amounts: [{ value: 82.5, currency: 'EUR' }],
  dates: ['2026-11-01', 'not a date'],
  keywords: ['tandarts', 'dentist', 'rekening'],
};

describe('mail facts', () => {
  it('flags secrets and personal numbers, and redacts them for the cloud bots', async () => {
    const s = await setup();
    const id = await s.deliver(s.home.id, {
      subject: 'Terugbetaling',
      bodyText: `Graag terugstorten op ${IBAN}, dank je!`,
    });
    const [message] = z
      .array(messageSummary)
      .parse(
        await (
          await s.call(s.token, `/api/mailboxes/${s.home.id}/messages`)
        ).json(),
      );
    expect(message?.facts).toMatchObject({
      sensitive: true,
      sensitiveKinds: ['iban'],
      source: 'rules',
    });

    s.decisions.push({
      action: { kind: 'keep' },
      reason: 'Fine.',
      unsure: false,
    });
    await s.triage.enqueue([id]);
    expect(s.agentRequests[0]?.prompt).toContain('[iban]');
    expect(s.agentRequests[0]?.prompt).not.toContain(IBAN);
  });

  it('hides login codes from search unless asked for', async () => {
    const s = await setup();
    await s.deliver(s.home.id, {
      subject: 'Je verificatiecode voor Netflix',
      bodyText: 'Gebruik 482913 om in te loggen.',
      from: { email: 'info@account.netflix.example' },
    });
    expect(await s.search(s.token, 'netflix')).toEqual([]);
    const [code] = await s.search(s.token, 'netflix', '&includeLow=true');
    expect(code?.facts).toMatchObject({ category: 'code', priority: 'low' });
  });

  it('lets Winky index mail on the owner Mac, only for people who turned it on', async () => {
    const s = await setup();
    await s.deliver(s.evas.id, { subject: 'Eva haar factuur' });
    const id = await s.deliver(s.home.id, {
      subject: 'Uw rekening',
      bodyText: 'Het bedrag van € 82,50 graag voor 1 november.',
      from: { name: 'Praktijk', email: 'praktijk@tandarts.example' },
    });
    expect(await s.claim(s.token)).toEqual([]);

    await s.indexing(s.token);
    await s.indexing(s.evaToken, false);
    const [task, ...rest] = await s.claim(s.token);
    expect(rest).toEqual([]);
    expect(task?.task).toMatchObject({ kind: 'hedwig.facts', queue: 'local' });
    expect(task?.request).toMatchObject({
      model: 'ollama:gemma4:26b-a4b',
      agent: 'local',
    });
    expect(task?.request.prompt).toContain('Uw rekening');
    expect(await s.claim(s.evaToken)).toEqual([]);

    const done = await s.post(
      s.token,
      `/api/runner/tasks/${task!.task.id}/complete`,
      answer,
    );
    expect(done.status).toBe(200);
    const [hit] = await s.search(s.token, 'dentist');
    expect(hit?.id).toBe(id);
    expect(hit?.facts).toMatchObject({
      category: 'invoice',
      summary: answer.summary,
      dates: ['2026-11-01'],
      source: 'model',
    });
    // Indexed mail is not handed out again, and the task list stays quiet.
    expect(await s.claim(s.token)).toEqual([]);
    expect(s.workers.list({ ...access(s), personId: s.gideon.id })).toEqual([]);
    const { work } = runnersResponse.parse(
      await (await s.call(s.token, '/api/runners')).json(),
    );
    expect(work).toContainEqual({
      queue: 'local',
      kind: 'hedwig.facts',
      title: 'Mail-facts',
      waiting: 0,
      done: 1,
    });
  });

  it('never lets a model lift the sensitive flag', async () => {
    const s = await setup();
    await s.indexing(s.token);
    const id = await s.deliver(s.home.id, {
      subject: 'Gegevens',
      bodyText: `Rekening ${IBAN}`,
    });
    const [task] = await s.claim(s.token);
    await s.post(s.token, `/api/runner/tasks/${task!.task.id}/complete`, {
      ...answer,
      sensitive: false,
    });
    const detail = messageSummary.parse(
      await (await s.call(s.token, `/api/messages/${id}`)).json(),
    );
    expect(detail.facts).toMatchObject({ sensitive: true, source: 'model' });
  });

  it('indexes mail that repeats once per template on Haiku, from redacted examples', async () => {
    const s = await setup();
    await s.indexing(s.token);
    for (const n of [101, 102, 103]) {
      await s.deliver(s.home.id, {
        subject: `Je pakket ${n}000 is onderweg`,
        bodyText: `Volg je pakket met code 48${n} via https://track.example/x`,
        from: { email: 'noreply@bezorger.example' },
      });
    }
    // The members wait for their template, not for Winky.
    expect(await s.claim(s.token)).toEqual([]);

    s.decisions.push({
      templates: [
        {
          n: 0,
          category: 'shipping',
          priority: 'low',
          summary: 'Pakket van de bezorger is onderweg',
          organisation: 'Bezorger',
          keywords: ['pakket', 'parcel', 'bezorging'],
        },
      ],
    });
    s.workers.pump();
    await s.workers.drain();
    const request = s.agentRequests.at(-1)!;
    expect(request.model).toBe('haiku');
    expect(request.prompt).toContain(
      'Subject pattern: je pakket # is onderweg',
    );
    expect(request.prompt).toContain('[code]');
    expect(request.prompt).not.toContain('48101');

    const results = await s.search(s.token, 'parcel', '&includeLow=true');
    expect(results).toHaveLength(3);
    expect(results.every((r) => r.facts?.source === 'template')).toBe(true);
  });

  it('gives a facts-only key the facts but never the mail', async () => {
    const s = await setup();
    const id = await s.deliver(s.home.id, {
      subject: 'Afspraak tandarts',
      bodyText: 'Geheim detail in de tekst',
    });
    const facts = s.key(s.gideon.id, ['read'], null, true);
    expect((await s.call(facts, `/api/messages/${id}`)).status).toBe(403);
    expect((await s.call(facts, `/api/messages/${id}/insights`)).status).toBe(
      403,
    );
    const list = z
      .array(messageSummary)
      .parse(
        await (
          await s.call(facts, `/api/mailboxes/${s.home.id}/messages`)
        ).json(),
      );
    expect(list[0]).toMatchObject({
      subject: 'Afspraak tandarts',
      snippet: '',
    });
    expect(await s.search(facts, 'geheim')).toEqual([]);
    expect(await s.search(s.token, 'geheim')).toHaveLength(1);
  });
});

const access = (s: Awaited<ReturnType<typeof setup>>) => ({
  keyId: 'test',
  keyName: 'test',
  personId: s.gideon.id,
  rights: new Set(['read' as const]),
  restrictions: {},
  factsOnly: false,
  mailboxIds: [s.home.id],
});
