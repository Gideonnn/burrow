import { claimedTask, routine, task } from '@burrow/contracts';
import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { testHousehold } from '../testing';

async function setup() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const eva = h.person('Eva');
  const home = h.mailbox(gideon.id, 'gideon@example.com');
  h.mailbox(eva.id, 'eva@example.com');
  const token = h.key(gideon.id, ['read', 'organize', 'tasks']);
  const evaToken = h.key(eva.id, ['read', 'organize', 'tasks']);
  const post = (key: string, path: string, body: unknown = {}) =>
    h.call(key, path, { method: 'POST', body: JSON.stringify(body) });
  return { ...h, gideon, eva, home, token, evaToken, post };
}

type Setup = Awaited<ReturnType<typeof setup>>;

const invoiceRoutine = {
  name: 'Factuur verwerken',
  trigger: { kind: 'message', label: 'Factuur' },
  skill: 'reply-suggestions',
  bot: 'kreacher',
};

const tasks = async (s: Setup, key: string) =>
  z.array(task).parse(await (await s.call(key, '/api/tasks')).json());

// The triage decision comes first in the bot queue, then what the routine's
// task run answers.
async function invoiceArrives(s: Setup, ...taskAnswers: object[]) {
  s.decisions.push(
    {
      action: { kind: 'label', label: 'Factuur' },
      reason: 'An invoice.',
      unsure: false,
    },
    ...taskAnswers,
  );
  s.provider(s.home.id).deliver({
    subject: 'Je factuur van oktober',
    from: { email: 'billing@example.com' },
  });
  await s.triage.enqueue(await s.mail.sync(s.home.id));
}

describe('routines', () => {
  it('starts a server task when triage labels a message, and waits for approval', async () => {
    const s = await setup();
    routine.parse(
      await (await s.post(s.token, '/api/routines', invoiceRoutine)).json(),
    );
    await invoiceArrives(s, {
      summary: 'Mailhost, € 5,00, already paid.',
      fields: { Totaal: '€ 5,00' },
      ops: [{ op: 'archive' }],
    });
    await s.routines.runOnServer('none');

    const [t] = await tasks(s, s.token);
    expect(t).toMatchObject({
      routineName: 'Factuur verwerken',
      status: 'review',
      result: { fields: { Totaal: '€ 5,00' } },
    });
    expect(s.provider(s.home.id).applied.map((a) => a.ops)).toEqual([
      [{ op: 'addLabel', label: 'Factuur' }],
    ]);

    await s.post(s.token, `/api/tasks/${t!.id}/approve`);
    expect((await tasks(s, s.token))[0]?.status).toBe('done');
    expect(s.provider(s.home.id).applied.at(-1)?.ops).toEqual([
      { op: 'archive' },
    ]);
  });

  it('does nothing when rejected', async () => {
    const s = await setup();
    await s.post(s.token, '/api/routines', invoiceRoutine);
    await invoiceArrives(s, { summary: 'x', ops: [{ op: 'archive' }] });
    await s.routines.runOnServer('none');
    const [t] = await tasks(s, s.token);
    await s.post(s.token, `/api/tasks/${t!.id}/reject`);
    expect((await tasks(s, s.token))[0]?.status).toBe('rejected');
    expect(s.provider(s.home.id).applied).toHaveLength(1);
  });

  it('refuses a result that tries to delete mail', async () => {
    const s = await setup();
    await s.post(s.token, '/api/routines', {
      ...invoiceRoutine,
      approval: false,
    });
    await invoiceArrives(s, { summary: 'x', ops: [{ op: 'trash' }] });
    await s.routines.runOnServer('none');
    expect((await tasks(s, s.token))[0]?.status).toBe('failed');
  });

  it('refuses a routine with a skill its bot may not use', async () => {
    const s = await setup();
    const res = await s.post(s.token, '/api/routines', {
      ...invoiceRoutine,
      skill: 'cooking',
    });
    expect(res.status).toBe(400);
  });

  it('runs schedule routines when they are due', async () => {
    const s = await setup();
    await s.post(s.token, '/api/routines', {
      ...invoiceRoutine,
      name: 'Ochtendbriefing',
      trigger: { kind: 'schedule', everyMinutes: 60 },
    });
    s.decisions.push({ summary: 'Goedemorgen.' }, { summary: 'Weer een uur.' });
    s.routines.tick(new Date('2026-10-19T07:00:00Z'));
    s.routines.tick(new Date('2026-10-19T07:30:00Z'));
    await s.routines.runOnServer('none');
    expect(await tasks(s, s.token)).toHaveLength(1);
    s.routines.tick(new Date('2026-10-19T08:00:00Z'));
    await s.routines.runOnServer('none');
    expect(await tasks(s, s.token)).toHaveLength(2);
  });
});

describe('client runners', () => {
  it('hand client tasks with a server-built request to the owner’s runner, and accept the result', async () => {
    const s = await setup();
    await s.post(s.token, '/api/routines', {
      ...invoiceRoutine,
      where: 'client',
      fallbackAfterHours: 24,
    });
    await invoiceArrives(s);

    expect(
      z
        .array(claimedTask)
        .parse(
          await (
            await s.post(s.evaToken, '/api/runner/claim', { runner: 'Mac Eva' })
          ).json(),
        ),
    ).toEqual([]);
    const [claimed] = z
      .array(claimedTask)
      .parse(
        await (
          await s.post(s.token, '/api/runner/claim', { runner: 'MacBook' })
        ).json(),
      );
    expect(claimed?.request.prompt).toContain('Je factuur van oktober');
    expect(claimed?.request.system).toContain('Suggest replies.');
    expect(
      await (
        await s.post(s.token, '/api/runner/claim', { runner: 'MacBook' })
      ).json(),
    ).toEqual([]);

    const done = await s.post(
      s.token,
      `/api/runner/tasks/${claimed!.task.id}/complete`,
      { summary: 'Verwerkt op de Mac.' },
    );
    expect(done.status).toBe(200);
    expect((await tasks(s, s.token))[0]).toMatchObject({
      status: 'review',
      claimedBy: 'MacBook',
    });
  });

  it('fall back to the server when no client picked the task up in time', async () => {
    const s = await setup();
    await s.post(s.token, '/api/routines', {
      ...invoiceRoutine,
      where: 'client',
      fallbackAfterHours: 24,
    });
    await invoiceArrives(s);
    s.decisions.push({ summary: 'Door de server gedaan.' });
    s.routines.tick(new Date(Date.now() + 25 * 3_600_000));
    await s.routines.runOnServer('none');
    expect((await tasks(s, s.token))[0]).toMatchObject({
      status: 'review',
      claimedBy: 'server',
    });
  });

  it('need the tasks right', async () => {
    const s = await setup();
    const reader = s.key(s.gideon.id, ['read', 'organize']);
    expect(
      (await s.post(reader, '/api/runner/claim', { runner: 'x' })).status,
    ).toBe(403);
  });
});
