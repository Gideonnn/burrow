import {
  claimedTask,
  messageDetail,
  messageSummary,
  searchResponse,
  sharedResponse,
  shareSuggestionsResponse,
} from '@burrow/contracts';
import { messageFacts, messages } from '@burrow/hedwig/server';
import { eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { testHousehold } from '../testing';

const claimed = z.array(claimedTask);
const daysAgo = (n: number) => new Date(Date.now() - n * 86_400_000);

async function setup({ alone = false } = {}) {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const eva = alone ? undefined : h.person('Eva');
  const home = h.mailbox(gideon.id, 'gideon@example.com');
  const token = h.key(gideon.id, ['read', 'organize', 'tasks']);
  const evaToken = eva ? h.key(eva.id, ['read', 'organize', 'tasks']) : '';
  const post = (key: string, path: string, body: unknown = {}) =>
    h.call(key, path, { method: 'POST', body: JSON.stringify(body) });
  const setting = (key: string, value: string) =>
    h.call(key, '/api/me/settings', {
      method: 'PATCH',
      body: JSON.stringify({ values: { 'hedwig.share': value } }),
    });
  let n = 0;
  const deliver = async (
    message: Partial<
      Parameters<ReturnType<typeof h.provider>['deliver']>[0]
    > = {},
  ) => {
    const i = ++n;
    const subject = message.subject ?? `Mail ${i}`;
    h.provider(home.id).deliver({
      receivedAt: new Date(daysAgo(1).getTime() + i * 60_000),
      ...message,
      subject,
    });
    await h.mail.sync(home.id);
    return h.db
      .select()
      .from(messages)
      .where(eq(messages.subject, subject))
      .get()!.id;
  };
  const claim = async (key: string) =>
    claimed.parse(
      await (
        await post(key, '/api/runner/claim', {
          runner: 'MacBook',
          kinds: ['hedwig.share'],
          queues: ['local'],
          models: ['ollama:gemma4:26b-a4b'],
          max: 5,
        })
      ).json(),
    );
  const complete = (key: string, taskId: string, answer: unknown) =>
    post(key, `/api/runner/tasks/${taskId}/complete`, answer);
  const search = async (key: string, q: string, extra = '') =>
    searchResponse
      .parse(
        await (
          await h.call(key, `/api/search?q=${encodeURIComponent(q)}${extra}`)
        ).json(),
      )
      .results.map((r) => r.subject);
  const suggestions = async (key: string) =>
    shareSuggestionsResponse.parse(
      await (await h.call(key, '/api/share/suggestions')).json(),
    ).suggestions;
  // Winky judges the next batch: every subject in `share` is household mail.
  const judge = async (share: string[]) => {
    const [task] = await claim(token);
    if (!task) return undefined;
    const subjects = [...task.request.prompt.matchAll(/^Subject: (.*)$/gm)].map(
      (m) => m[1]!,
    );
    const done = await complete(token, task.task.id, {
      mails: subjects.map((s, i) => ({
        n: i + 1,
        share: share.includes(s),
        reason: share.includes(s) ? 'energierekening' : 'werkmail',
      })),
    });
    expect(done.status).toBe(200);
    return subjects;
  };
  return {
    ...h,
    gideon,
    eva: eva!,
    home,
    token,
    evaToken,
    post,
    setting,
    deliver,
    claim,
    complete,
    search,
    suggestions,
    judge,
  };
}

describe('sharing a message', () => {
  it('lets Eva find and open what Gideon shared, never organize it, and hides it again once unshared', async () => {
    const s = await setup();
    const bill = await s.deliver({
      subject: 'Jaarafrekening energie',
      bodyText: 'Uw jaarafrekening voor de Lindelaan 4.',
    });
    await s.deliver({
      subject: 'Offerte energie dashboard',
      bodyText: 'De offerte voor het energie dashboard van de klant.',
    });

    expect(await s.search(s.evaToken, 'energie')).toEqual([]);
    expect((await s.call(s.evaToken, `/api/messages/${bill}`)).status).toBe(
      404,
    );

    const shared = await s.post(s.token, `/api/messages/${bill}/share`, {
      personId: s.eva.id,
    });
    expect(shared.status).toBe(200);
    expect(messageSummary.parse(await shared.json()).share).toEqual({
      by: null,
      with: [s.eva.id],
    });

    expect(await s.search(s.evaToken, 'energie')).toEqual([
      'Jaarafrekening energie',
    ]);
    // Only a search everywhere looks in shared mail.
    expect(await s.search(s.evaToken, 'energie', '&folder=inbox')).toEqual([]);
    const opened = await s.call(s.evaToken, `/api/messages/${bill}`);
    expect(opened.status).toBe(200);
    const detail = messageDetail.parse(await opened.json());
    expect(detail.bodyText).toContain('Lindelaan 4');
    expect(detail.share).toEqual({ by: s.gideon.id, with: [s.eva.id] });
    expect(
      (await s.call(s.evaToken, `/api/messages/${bill}/attachments`)).status,
    ).toBe(200);

    expect(
      (
        await s.post(s.evaToken, `/api/messages/${bill}/actions`, {
          ops: [{ op: 'archive' }],
        })
      ).status,
    ).toBe(404);
    expect(
      (
        await s.post(s.evaToken, `/api/messages/${bill}/share`, {
          personId: s.eva.id,
        })
      ).status,
    ).toBe(404);
    const factsOnly = s.key(s.eva.id, ['read'], null, true);
    expect((await s.call(factsOnly, `/api/messages/${bill}`)).status).toBe(404);

    const lists = async (key: string) =>
      sharedResponse.parse(await (await s.call(key, '/api/shared')).json());
    expect((await lists(s.evaToken)).withMe.map((m) => m.id)).toEqual([bill]);
    expect((await lists(s.token)).byMe.map((m) => m.id)).toEqual([bill]);

    const unshared = await s.call(
      s.token,
      `/api/messages/${bill}/share/${s.eva.id}`,
      { method: 'DELETE' },
    );
    expect(unshared.status).toBe(200);
    expect(await s.search(s.evaToken, 'energie')).toEqual([]);
    expect((await s.call(s.evaToken, `/api/messages/${bill}`)).status).toBe(
      404,
    );
    expect((await lists(s.evaToken)).withMe).toEqual([]);
  });

  it('refuses sharing with the owner or someone outside the household', async () => {
    const s = await setup();
    const id = await s.deliver();
    const to = (personId: string) =>
      s.post(s.token, `/api/messages/${id}/share`, { personId });
    expect((await to(s.gideon.id)).status).toBe(400);
    expect((await to('nobody')).status).toBe(400);
  });
});

describe('Winky suggests household mail', () => {
  it('judges only recent mail that could be household mail, and shows the suggestion to its owner', async () => {
    const s = await setup();
    const bill = await s.deliver({
      subject: 'Uw energierekening',
      from: { name: 'Stroom', email: 'factuur@stroom.example' },
    });
    await s.deliver({ subject: 'Offerte website' });
    await s.deliver({ subject: 'Spam', folder: 'spam' });
    await s.deliver({ subject: 'Oud', receivedAt: daysAgo(300) });
    await s.deliver({
      subject: 'Je verificatiecode voor Netflix',
      bodyText: 'Gebruik 482913 om in te loggen.',
      from: { email: 'info@account.netflix.example' },
    });
    const letter = await s.deliver({ subject: 'Nieuwsbrief' });
    s.db
      .update(messageFacts)
      .set({ category: 'newsletter' })
      .where(eq(messageFacts.messageId, letter))
      .run();

    expect(await s.judge(['Uw energierekening'])).toEqual([
      'Offerte website',
      'Uw energierekening',
    ]);
    expect(await s.claim(s.token)).toEqual([]);

    const [suggestion, ...rest] = await s.suggestions(s.token);
    expect(rest).toEqual([]);
    expect(suggestion).toMatchObject({
      reason: 'energierekening',
      message: { id: bill, shareSuggestion: { reason: 'energierekening' } },
    });
    expect(await s.suggestions(s.evaToken)).toEqual([]);
    expect(await s.search(s.evaToken, 'energierekening')).toEqual([]);

    const done = await s.post(s.token, `/api/share/suggestions/${bill}`, {
      decision: 'share',
    });
    expect(done.status).toBe(200);
    expect(messageSummary.parse(await done.json())).toMatchObject({
      share: { with: [s.eva.id] },
      shareSuggestion: null,
    });
    expect(await s.search(s.evaToken, 'energierekening')).toEqual([
      'Uw energierekening',
    ]);
    expect(await s.suggestions(s.token)).toEqual([]);
  });

  it('stops suggesting mail from a sender dismissed twice', async () => {
    const s = await setup();
    const from = { name: 'Makelaar', email: 'info@makelaar.example' };
    const first = await s.deliver({ subject: 'Woning 1', from });
    const second = await s.deliver({ subject: 'Woning 2', from });
    await s.judge(['Woning 1', 'Woning 2']);
    for (const id of [first, second]) {
      const r = await s.post(s.token, `/api/share/suggestions/${id}`, {
        decision: 'dismiss',
      });
      expect(r.status).toBe(200);
    }
    await s.deliver({ subject: 'Woning 3', from });
    await s.deliver({ subject: 'Huur november' });
    expect(await s.judge(['Huur november'])).toEqual(['Huur november']);
    expect(
      (await s.suggestions(s.token)).map((x) => x.message.subject),
    ).toEqual(['Huur november']);
  });

  it('shares by itself what comes from a sender marked always', async () => {
    const s = await setup();
    const from = { name: 'Verzekeraar', email: 'polis@verzekeraar.example' };
    const first = await s.deliver({ subject: 'Polis inboedel', from });
    await s.judge(['Polis inboedel']);
    await s.post(s.token, `/api/share/suggestions/${first}`, {
      decision: 'share',
      always: true,
    });
    await s.deliver({ subject: 'Nieuwe polis auto', from });
    await s.judge(['Nieuwe polis auto']);
    expect(await s.suggestions(s.token)).toEqual([]);
    expect((await s.search(s.evaToken, 'polis')).sort()).toEqual([
      'Nieuwe polis auto',
      'Polis inboedel',
    ]);
  });

  it('shares every suggestion itself with Winky deelt zelf, and undoing counts as a dismissal', async () => {
    const s = await setup();
    expect((await s.setting(s.token, 'auto')).status).toBe(200);
    const from = { name: 'Reisbureau', email: 'boeking@reis.example' };
    const trip = await s.deliver({ subject: 'Boeking Texel', from });
    await s.deliver({ subject: 'Offerte logo' });
    await s.judge(['Boeking Texel']);
    expect(await s.suggestions(s.token)).toEqual([]);
    expect(await s.search(s.evaToken, 'texel')).toEqual(['Boeking Texel']);

    await s.call(s.token, `/api/messages/${trip}/share/${s.eva.id}`, {
      method: 'DELETE',
    });
    expect(await s.search(s.evaToken, 'texel')).toEqual([]);
    const again = await s.deliver({ subject: 'Boeking Ameland', from });
    await s.judge(['Boeking Ameland']);
    await s.call(s.token, `/api/messages/${again}/share/${s.eva.id}`, {
      method: 'DELETE',
    });
    await s.deliver({ subject: 'Boeking Vlieland', from });
    expect(await s.claim(s.token)).toEqual([]);
  });

  it('gives Winky nothing to judge with sharing off or alone in the house', async () => {
    const s = await setup();
    await s.deliver({ subject: 'Uw energierekening' });
    await s.setting(s.token, 'off');
    expect(await s.claim(s.token)).toEqual([]);

    const alone = await setup({ alone: true });
    await alone.deliver({ subject: 'Uw energierekening' });
    expect(await alone.claim(alone.token)).toEqual([]);
  });

  it('waits for the facts when Winky indexes the mail, and judges with their summary', async () => {
    const s = await setup();
    await s.call(s.token, '/api/me/settings', {
      method: 'PATCH',
      body: JSON.stringify({ values: { 'hedwig.facts': true } }),
    });
    await s.deliver({ subject: 'Uw rekening' });
    expect(await s.claim(s.token)).toEqual([]);
    const [facts] = claimed.parse(
      await (
        await s.post(s.token, '/api/runner/claim', {
          runner: 'MacBook',
          kinds: ['hedwig.facts'],
          queues: ['local'],
          models: ['ollama:gemma4:26b-a4b'],
        })
      ).json(),
    );
    await s.complete(s.token, facts!.task.id, {
      category: 'invoice',
      priority: 'high',
      sensitive: false,
      summary: 'De jaarafrekening van het water voor het huis.',
      people: [],
      organisations: ['Waterbedrijf'],
      amounts: [],
      dates: [],
      keywords: [],
    });
    const [task] = await s.claim(s.token);
    expect(task?.request.prompt).toContain(
      'Summary: De jaarafrekening van het water',
    );
  });

  it('tries a mail Winky skipped once more, then gives up on it', async () => {
    const s = await setup();
    await s.deliver({ subject: 'Uw energierekening' });
    for (let i = 0; i < 2; i++) {
      const [task] = await s.claim(s.token);
      expect(task).toBeDefined();
      await s.complete(s.token, task!.task.id, { mails: [] });
    }
    expect(await s.claim(s.token)).toEqual([]);
  });
});
